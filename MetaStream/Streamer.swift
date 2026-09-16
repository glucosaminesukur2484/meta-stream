import Foundation
import Combine
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit
import Network
import os
import MWDATCore
import MWDATCamera
import HaishinKit
import RTMPHaishinKit
import SRTHaishinKit

struct Mic: Identifiable, Hashable { let id: String; let name: String }   // id = AVAudioSessionPortDescription.uid

/// State the SDK's frame thread reads 30×/s without hopping to the main actor. Publishing per frame made
/// SwiftUI re-render the whole screen at 30 fps (54% CPU, iOS cpu_resource report); now stats publish once a second.
// ponytail: plain vars behind @unchecked Sendable; counters can race by a frame, which the HUD can't show anyway.
private final class Hot: @unchecked Sendable {
    var live = false
    var forward = true                 // source == "glasses" && !cameraOff
    var frames = 0
    var bytes = 0
    var transcoder: Transcoder?         // non-nil = decode HEVC → H.264 encoder instead of passthrough
    var warm = false                    // decoder warming up before the RTMP connect
    var sent = 0                        // glasses frames handed to the RTMP path
    var appended = 0                    // decoded frames handed to the mixer (IN)
    var mixerOut = 0                    // composited frames the mixer actually emitted (OUT) -- see LayerSink below.
                                         // appended climbing while this stalls is output starvation, not input starvation
                                         // (this is the diagnostic that would have caught the offscreen-mode freeze without a device).
    var showMixerVideo = false          // preview shows mixer output (phone camera / black) instead of glasses frames
    weak var preview: AVSampleBufferDisplayLayer?
    // Outbound-pressure telemetry for the bitrate controller (acted on only while Streamer.phoneEncodes is
    // true). Written by QueueWatcher below (HaishinKit's own NetworkMonitor callback), read once a second by
    // Streamer's existing stats loop. Same race tolerance as frames/bytes above: worst case a stale tick.
    var queueBytesOut = 0
    var bytesOutPerSecond = 0
    var congested = false               // latched by QueueWatcher on .publishInsufficientBWOccured; edge-consumed
}

/// Captures HaishinKit's NetworkMonitor reports into `hot`; does no bitrate math itself. The actual AIMD
/// decision runs in Streamer's existing 1s stats loop, not here — NetworkMonitor is `package`-scoped
/// (checked HaishinKit 2.1.0 source directly), so this StreamBitRateStrategy callback is the only public
/// door onto outbound queue/throughput. mamimumVideo/AudioBitRate are unused (we don't let this type touch
/// bitrate) but are `let`s so they're readable off-actor without await, same trick HaishinKit's own
/// StreamVideoAdaptiveBitRateStrategy uses.
private actor QueueWatcher: StreamBitRateStrategy {
    let mamimumVideoBitRate = 0
    let mamimumAudioBitRate = 0
    private let hot: Hot
    init(hot: Hot) { self.hot = hot }
    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report):
            hot.queueBytesOut = report.currentQueueBytesOut
            hot.bytesOutPerSecond = report.currentBytesOutPerSecond
        case .publishInsufficientBWOccured(let report):
            hot.queueBytesOut = report.currentQueueBytesOut
            hot.bytesOutPerSecond = report.currentBytesOutPerSecond
            hot.congested = true
        case .reset:
            break
        }
    }
}

/// Mirrors the mixer's video (phone camera, black frames, and -- while blur is on -- decoded glasses frames)
/// into the same preview layer the glasses use, so one layer feeds the screen and Picture in Picture whatever
/// the source is. videoTrackId == UInt8.max (not a specific track number) is deliberate: that's HaishinKit's
/// sentinel for the mixer's final rendered/composited output -- the exact same tap RTMPStream/SRTStream use
/// (checked HaishinKit 2.1.0 source: both default videoTrackId to UInt8.max) -- so this shows whatever
/// actually goes out, effects included. A specific track number instead (e.g. 0) taps the RAW per-track
/// input before Screen/effects ever see it, in every mixer mode; that was the bug that kept the local
/// preview looking clean while blur silently did nothing to it.
private final class LayerSink: MediaMixerOutput, @unchecked Sendable {
    private let hot: Hot
    init(hot: Hot) { self.hot = hot }
    var videoTrackId: UInt8? { UInt8.max }
    var audioTrackId: UInt8? { nil }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        hot.mixerOut += 1   // counted regardless of preview state -- this is the mixer's composited-output tap firing, full stop
        guard hot.showMixerVideo, let p = hot.preview else { return }
        if p.status == .failed { p.flush() }
        p.enqueue(sampleBuffer)
    }
    func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {}
    func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {}
}

@MainActor
final class Streamer: ObservableObject {
    @Published var registration = "unknown"
    @Published var glassesState = "idle" { didSet { applog("glasses", "\(glassesState)") } }
    @Published var glassesOn = false
    @Published var rtmpState = "idle" { didSet { applog("stream", "rtmp: \(rtmpState)") } }
    @Published var frames = 0
    @Published var fps = 0
    @Published var kbps = 0
    @Published var teamID = "unknown (not sideloaded yet)"
    @Published var live = false { didSet { hot.live = live } }
    @Published var liveSince: Date?
    @Published var connectedSince: Date?        // when the CURRENT connection went up; nil while down
    @Published var downtime: TimeInterval = 0   // cumulative seconds this session spent not publishing
    @Published var drops = 0                    // times the connection dropped this session
    @Published var sessionSummary: String?      // set by stopLive(), e.g. "session 42:10, 1:48 down across 3 drops"
    @Published var devices = "none seen yet"
    @Published var source = "glasses" { didSet { syncHot(); applog("stream", "source=\(source) manual=\(manualSource)") } }   // what is going out right now
    @Published var manualSource = "auto"       // "auto" | "glasses" | "back" | "front" (user's choice)
    @Published var mics: [Mic] = []
    @Published var muted = false
    @Published var cameraOff = false { didSet { syncHot() } }   // black frames go out instead

    private func syncHot() {
        hot.forward = source == "glasses" && !cameraOff
        // The glasses preview normally shows the raw HEVC stream directly (AVSampleBufferDisplayLayer decodes
        // it itself -- lower latency than round-tripping through the mixer), but that raw stream can never be
        // blurred: it never reaches the mixer (see the ADR). While glasses frames are actually being decoded
        // (warm or live, H.264 mode) with blur on, route the preview through the mixer instead, same as phone
        // camera/black frames, so the streamer sees what's actually going out rather than a clean picture that
        // silently isn't what the audience gets. Called from goLive()/stopLive()/syncBlurEffect() too, since
        // those flip the state this depends on without themselves being observed properties.
        let glassesBlurredLive = hot.forward && hot.transcoder != nil && (hot.live || hot.warm) && (privacy?.enabled == true)
        let show = source == "phone" || cameraOff || glassesBlurredLive
        if show != hot.showMixerVideo { hot.showMixerVideo = show; hot.preview?.flush() }   // format switches between sources
    }
    @Published var lastPhotoAt: Date?
    private var blackTask: Task<Void, Never>?

    // MARK: health
    // ponytail: no glasses battery — MWDATCore 0.9.0 has no battery API anywhere on Device/DeviceState
    // (checked the full 0.9 type index, not just one page). Thermal is the one piece of glasses health
    // the SDK actually exposes, via DeviceState.thermalLevel — see glassesThermal below.
    @Published var glassesThermal: ThermalLevel? { didSet { checkGlassesThermal() } }   // nil when unknown/disconnected
    @Published var phoneBattery: Int? { didSet { checkPhoneBattery() } }      // nil when unknown; unmonitored outside a live session
    @Published var thermal: ProcessInfo.ThermalState = .nominal { didSet { checkThermal() } }

    // MARK: adaptive bitrate (active whenever phoneEncodes is true — see below)
    /// True when HaishinKit decodes+re-encodes this session. Blur can only apply to a frame we decode,
    /// so a passthrough session cannot start blurring mid-stream — the quick control says so rather than
    /// pretending the toggle worked.
    @Published private(set) var transcoding = false
    @Published var currentBitrateKbps = 0     // live value for the HUD; == configured target while phoneEncodes is false
    private var bitrateCeilingKbps = 0        // user's configured bitrateKbps; up-steps never exceed this
    private var thermalCeilingKbps: Int?      // set while thermal >= .serious; caps the ceiling until it clears
    private var cleanTicks = 0                // consecutive good 1s ticks; 15 triggers an up-step
    private var lastBitrateAdjustAt: Date?    // rate limit: one adjustment per bitrateAdjustCooldown
    private let bitrateAdjustCooldown: TimeInterval = 3
    private let bitrateFloorKbps = 500
    /// True whenever HaishinKit's own encoder is doing the work: h264 transcode (any source), or hevc with
    /// the phone driving video — phone-camera fallback (source == "phone") or black frames (cameraOff).
    /// False only for hevc glasses passthrough, the one case with no bitrate knob (see goLive's gate comment).
    private var phoneEncodes: Bool { hot.transcoder != nil || source == "phone" || cameraOff }

    /// Short glasses state for the HUD: "streaming" | "connecting" | "off".
    var glassesShort: String {
        let s = glassesState.lowercased()
        if s.contains("streaming") { return "streaming" }
        if ["starting", "looking", "waiting", "connecting", "session started"].contains(where: { s.contains($0) }) { return "connecting" }
        return "off"
    }

    // ponytail: ContentView sets this directly instead of a delegate protocol.
    var preview: AVSampleBufferDisplayLayer? {
        get { hot.preview }
        set { hot.preview = newValue }
    }

    /// The phone camera physically attached to the mixer right now -- nil whenever glasses or black frames
    /// are the source. Set after switchTo(glasses:)'s phone branch attaches (post-await, so this runs back
    /// on the main actor -- no isolation ambiguity with the attachVideo configuration closure itself), and
    /// cleared at every other mixer.attachVideo(nil) call site (switchTo's glasses branch, setCameraOff,
    /// stopLive). Live sliders patch THIS device in place via applyCameraSettings() below instead of
    /// re-attaching -- re-attaching per slider tick would visibly glitch the preview, and live, the outgoing
    /// stream, many times a second.
    private(set) var cameraDevice: AVCaptureDevice?
    /// What the live control strip can offer for the currently attached device -- the same struct/probe
    /// SettingsView's Camera screen uses (CameraCapabilities.probe), refreshed on every attach so front/back
    /// and lens differences show up immediately instead of stale-showing whatever the last camera supported.
    @Published private(set) var cameraCapabilities: CameraCapabilities?
    /// Mirrors fallbackPosition (private, below) for the live strip's lens filter -- setSource("front"/"back")
    /// can change the real attached position without touching @AppStorage("fallbackCamera") at all (that key
    /// is only Settings' fallback *preference*, read at evaluateSource() time), so the strip needs this
    /// rather than reading that AppStorage key directly and risking a stale/wrong lens list.
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back

    private let hot = Hot()
    private lazy var sink = LayerSink(hot: hot)
    var pip: PiPController?                        // owned here so it outlives SwiftUI view rebuilds
    // ponytail: plain optional, not weak — Speaker never references Streamer, so no retain cycle. App.swift sets it once.
    var speaker: Speaker?
    var privacy: Privacy?
    private var blurHidCamera = false
    private var blurEffectActive = false   // mirrors privacy.enabled -- tracks whether the effect is registered on mixer.screen
    private var lastFrames = 0
    private var lastBytes = 0

    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []        // SDK listeners die when their token is released
    private var deviceTokens: [any AnyListenerToken] = []  // per-device link/compat listeners
    private var glassesStreaming = false
    private var fallbackTask: Task<Void, Never>?
    private var fallbackPosition: AVCaptureDevice.Position = .back
    private var reconnectTask: Task<Void, Never>?   // covers first connect + every drop; cancelled by stopLive()
    private var downSince: Date?                    // set while not connected — before the first connect too
    private var escalated2m = false
    private var escalated5m = false
    private var backoff: TimeInterval = 1
    private var warnedPhoneBattery = false     // < 15%, once per session — reset in goLive()
    private var warnedThermal = false          // >= .serious, once per session — reset in goLive()
    private var warnedGlassesThermal = false   // >= .severe, once per session — reset in goLive()
    private var batteryObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var glassesThermalTask: Task<Void, Never>?

    // ponytail: an enum beats a protocol here. RTMPStream and SRTStream already share
    // StreamConvertible for append/settings/bitrate and diverge only on connect/publish/close/
    // connected, so four switches cost less than an abstraction over two actor types.
    enum Uplink: Sendable {
        case rtmp(RTMPConnection, RTMPStream)
        case srt(SRTConnection, SRTStream)

        static func make(for url: String) -> Uplink {
            if url.lowercased().hasPrefix("srt://") {
                let c = SRTConnection()
                return .srt(c, SRTStream(connection: c))
            }
            let c = RTMPConnection()      // advertises hvc1 in the enhanced-RTMP connect by default
            return .rtmp(c, RTMPStream(connection: c))
        }

        var isSRT: Bool { if case .srt = self { return true }; return false }

        func connect(_ url: String) async throws {
            switch self {
            case .rtmp(let c, _): _ = try await c.connect(url)
            case .srt(let c, _): try await c.connect(URL(string: url))   // SRT takes a URL, not a String
            }
        }

        /// SRT has no publish name — the stream key rides in the URL's `streamid` query item.
        func publish(_ key: String) async throws {
            switch self {
            case .rtmp(_, let st): _ = try await st.publish(key)
            case .srt(_, let st): try await st.publish()
            }
        }

        var connected: Bool {
            get async {
                switch self {
                case .rtmp(let c, _): return await c.connected
                case .srt(let c, _): return await c.connected
                }
            }
        }

        func close() async {
            switch self {
            case .rtmp(let c, _): try? await c.close()
            case .srt(let c, _): await c.close()                         // SRT's close doesn't throw
            }
        }

        func append(_ sb: CMSampleBuffer) async {
            switch self {
            case .rtmp(_, let st): await st.append(sb)
            case .srt(_, let st): await st.append(sb)
            }
        }

        /// The underlying stream as a MediaMixerOutput -- both RTMPStream and SRTStream default their own
        /// videoTrackId/audioTrackId to UInt8.max (checked HaishinKit 2.1.0/2.2.5 source: HaishinKit's own
        /// MTHKView/PiPHKView preview views do too, alongside a stream, as the documented way to tap the
        /// mixer's composited output from more than one place -- addOutput/removeOutput just append/remove
        /// from a plain array and every dispatch site loops `for output in outputs where videoTrackId == ...`,
        /// so registering this next to LayerSink is not a collision). Used by wireMixer() below to swap which
        /// stream is registered when goLive() rebuilds `uplink` for a new session.
        var output: any MediaMixerOutput {
            switch self {
            case .rtmp(_, let st): return st
            case .srt(_, let st): return st
            }
        }

        func setBitRateStrategy(_ s: some StreamBitRateStrategy) async {
            switch self {
            case .rtmp(_, let st): await st.setBitRateStrategy(s)
            case .srt(_, let st): await st.setBitRateStrategy(s)
            }
        }

        var videoSettings: VideoCodecSettings {
            get async {
                switch self {
                case .rtmp(_, let st): return await st.videoSettings
                case .srt(_, let st): return await st.videoSettings
                }
            }
        }

        func setAudioSettings(_ a: AudioCodecSettings) async {
            switch self {
            case .rtmp(_, let st): try? await st.setAudioSettings(a)
            case .srt(_, let st): try? await st.setAudioSettings(a)
            }
        }

        /// RTMP-only diagnostic: every NetConnection.*/NetStream.* status the server sends.
        /// SRT has no equivalent, so this simply returns for an SRT uplink.
        func logStatus() async {
            guard case .rtmp(let c, _) = self else { return }
            for await st in await c.status { applog("stream", "rtmp status: \(st.code) \(st.description)") }
        }

        func setVideoSettings(_ v: VideoCodecSettings) async {
            switch self {
            case .rtmp(_, let st): try? await st.setVideoSettings(v)
            case .srt(_, let st): try? await st.setVideoSettings(v)
            }
        }
    }

    /// What the phone camera captures and the encoder targets. Only applies while the phone is the video
    /// source: the glasses hand over 720x1280 at up to 30 fps and Meta's SDK offers third-party apps
    /// nothing higher, so these settings cannot raise that — they exist so the app is useful without glasses.
    struct PhoneQuality: Sendable {
        /// 720, 1080 or 2160 -- whichever CameraFormatCapabilities.probe() found this lens/position
        /// actually has a format for (SettingsView.CameraSettingsView drives the picker off that; this
        /// struct just carries whatever height goLive() was last called with, same as before 4K support).
        var height = 720
        var landscape = false
        var fps = 30                      // whatever CameraFormatCapabilities said this resolution supports
        /// "off" | "standard" | "cinematic" | "action". Phone camera only — the glasses stabilise in
        /// hardware and hand over already-encoded video the app never touches uncompressed.
        var stabilization = "off"

        /// Encoder frame size. Portrait is the glasses-native orientation; landscape is 16:9 for everything
        /// else. long is derived (height * 16/9), not a 720/1080-only lookup, so 4K (2160 -> 3840) falls
        /// out of the same formula rather than needing its own case.
        var size: CGSize {
            let short = CGFloat(height), long = short * 16 / 9
            return landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        }
        /// AVCaptureSession.Preset has no way to derive its name from a number -- this mapping is just
        /// that plumbing, not a capability assumption; CameraFormatCapabilities.probe (device-side) is
        /// what actually decides which of these three a given lens/position offers in Settings.
        var sessionPreset: AVCaptureSession.Preset {
            switch height {
            case 2160: return .hd4K3840x2160
            case 1080: return .hd1920x1080
            default: return .hd1280x720
            }
        }
    }

    /// The glasses' fixed output. Not configurable — see PhoneQuality.
    static let glassesSize = CGSize(width: 720, height: 1280)

    /// Apple's "Action mode" is Camera-app branding for the extended cinematic algorithm; AVFoundation
    /// exposes it as a stabilisation mode on the capture connection. `.cinematicExtendedEnhanced` is the
    /// strongest and needs iOS 18, so anything older falls back to `.cinematicExtended`.
    /// ponytail: sets the REQUESTED mode only — AVFoundation quietly ignores one the active format cannot
    /// do, and `activeVideoStabilizationMode` is where to look if that ever needs surfacing in the UI.
    /// nonisolated: pure String -> enum mapping, no Streamer state -- CameraFormatCapabilities.probe
    /// (CameraSettings.swift, not MainActor) calls this off the main actor to check per-format support;
    /// without this it's a Swift 6 cross-actor call error, the exact trap this file's header warns about.
    nonisolated static func stabilizationMode(_ name: String) -> AVCaptureVideoStabilizationMode {
        switch name {
        case "standard": return .standard
        case "cinematic": return .cinematic
        case "action":
            if #available(iOS 18.0, *) { return .cinematicExtendedEnhanced }
            return .cinematicExtended
        default: return .off
        }
    }

    private var phoneQuality = PhoneQuality()
    /// Geometry the current session fixed at goLive, reused as the offscreen blur canvas.
    private var sessionVideoSize = Streamer.glassesSize
    /// True from the moment goLive() fixes the geometry until stopLive(). `live` is no good here: it
    /// only flips once the first publish succeeds, long after the blur canvas needs sizing.
    private var sessionGeometryFixed = false

    /// libsrt defaults latency to ~120 ms, tuned for clean links; a phone walking through a city needs
    /// far more buffer. Applied only if the user hasn't set it themselves in the URL.
    static func withSRTLatency(_ url: String, ms: Int) -> String {
        guard url.lowercased().hasPrefix("srt://"), !url.lowercased().contains("latency=") else { return url }
        return url + (url.contains("?") ? "&" : "?") + "latency=\(ms)"
    }

    /// Rebuilt per goLive() from the ingest URL's scheme.
    private var uplink = Uplink.make(for: "rtmp://")
    private let mixer = MediaMixer()
    private var mixerWired = false
    /// Whichever uplink's stream is currently registered as a mixer output, so a later goLive() can swap it
    /// out. FOUND BUG: `mixer.addOutput(uplink.output)` used to run only on the very first wireMixer() call
    /// ever (guarded by mixerWired alone) -- goLive() rebuilds `uplink` into a brand-new RTMPStream/SRTStream
    /// every session, but nothing ever added THAT one as a mixer output once mixerWired had already latched
    /// true from an earlier session (or from evaluateSource()'s auto phone-camera fallback at launch, which
    /// also calls wireMixer()). The mixer kept feeding the FIRST session's now-closed, orphaned stream while
    /// every later session connected, published, and sat there receiving zero frames of either kind -- a
    /// stream with no track at all, which is exactly "connected, publishing, channel stayed offline" with no
    /// device-report codec/track-config error to explain it. This is what actually explains that report; a
    /// shared UInt8.max videoTrackId with LayerSink (checked directly above) was considered and ruled out --
    /// HaishinKit's own dispatch is a plain array loop with no exclusivity, and its own preview views use the
    /// identical pattern deliberately.
    private var wiredUplinkOutput: (any MediaMixerOutput)?

    /// Phone-camera frames flow mixer → encoder → RTMP stream (and → preview view). sink/startRunning() are
    /// wired once, on first need (HaishinKit's own startRunning() no-ops on a repeat call regardless -- checked
    /// both tags); the uplink's own stream is re-registered every call whenever `uplink` itself has changed.
    private func wireMixer() async {
        if wiredUplinkOutput !== uplink.output {
            if let old = wiredUplinkOutput { await mixer.removeOutput(old) }
            await mixer.addOutput(uplink.output)
            wiredUplinkOutput = uplink.output
            // mixerOut (see Hot/LayerSink) alone can't catch a repeat of the bug above: LayerSink is wired
            // once and stays wired regardless, so it keeps counting normally even in a session whose uplink
            // stream was never registered. This line is what makes THAT specific failure grep-able per session.
            applog("stream", "mixer output wired to current uplink stream")
        }
        guard !mixerWired else { return }
        mixerWired = true
        await mixer.addOutput(sink)
        await mixer.startRunning()
    }

    init() {
        teamID = Self.readTeamID()
        applog("ui", "launch team=\(teamID)")
        // Active playback session from launch: iOS only auto-starts PiP for an app that is "playing".
        // Playback (not record) so the orange mic indicator stays off until Go Live.
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [])
        try? s.setActive(true)
        Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                self?.registration = state.description
            }
        }
        Task { [weak self] in
            for await ids in Wearables.shared.devicesStream() {
                self?.watchDevices(ids)
            }
        }
        evaluateSource()                                // glasses off at launch → phone camera after 2 s
        Task { [weak self] in                           // 1 s stats tick for the HUD, logged every 5 s while live
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let f = self.hot.frames, b = self.hot.bytes
                self.fps = f - self.lastFrames
                self.kbps = (b - self.lastBytes) * 8 / 1000
                self.frames = f
                self.lastFrames = f; self.lastBytes = b
                tick += 1
                await self.adaptBitrate()
                await self.syncBlurEffect()
                self.checkBlurStall()
                if self.live, tick % 5 == 0 {
                    let mode = self.hot.transcoder == nil ? "hevc-passthrough" : "h264-transcode"
                    applog("stream", "stats source=\(self.source) \(mode) glassesFps=\(self.fps) glassesKbps=\(self.kbps) sent=\(self.hot.sent) decoded=\(self.hot.transcoder?.decoded ?? 0) appended=\(self.hot.appended) mixerOut=\(self.hot.mixerOut)")
                }
            }
        }
    }

    // MARK: glasses

    func register() {
        Task {
            do { try await Wearables.shared.startRegistration() } catch { registration = error.localizedDescription }
        }
    }

    // Same order as Meta's CameraAccess sample: session.start() → wait for .started → addCamera → stream.start().
    func startGlasses(resolution: String = "high", fps: UInt = 30, attempt: Int = 1) {
        glassesOn = true
        Task {
            do {
                // ponytail: not branching on the returned status; createSession fails anyway if denied.
                _ = try await Wearables.shared.requestPermission(.camera)

                // The SDK fills its device list asynchronously after registration; give it up to 10 s.
                let selector = AutoDeviceSelector(wearables: Wearables.shared)
                glassesState = "looking for glasses…"
                var tries = 0
                while selector.activeDevice == nil, tries < 20 {   // ponytail: 0.5 s poll instead of racing activeDeviceStream
                    try await Task.sleep(for: .milliseconds(500)); tries += 1
                }
                guard let id = selector.activeDevice, let device = Wearables.shared.deviceForIdentifier(id) else {
                    glassesState = "no linked glasses. Open Meta AI, make sure glasses are connected, then retry"
                    glassesOn = false
                    return
                }
                switch device.compatibility() {
                case .deviceUpdateRequired:
                    glassesState = "glasses firmware too old, opening Meta AI update"
                    glassesOn = false
                    try await Wearables.shared.openFirmwareUpdate()
                    return
                case .sdkUpdateRequired:
                    glassesState = "app SDK too old for these glasses, rebuild with newer DAT"
                    glassesOn = false
                    return
                default: break
                }

                let session = try Wearables.shared.createSession(deviceSelector: selector)
                self.session = session
                tokens.append(session.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        self.glassesState = "session \(state.description)"
                        // ponytail: no HingeState to read — MWDATCore 0.9.0 has no such type (see the
                        // health-properties comment above). Meta's own AGENTS.md says folding the hinge
                        // drops Bluetooth and forces the session to .stopped, so treat .stopped as the
                        // fold proxy: skip the 2 s frame-loss debounce in evaluateSource() and switch to
                        // the phone camera right away. Never ends the broadcast — that's stopLive()'s
                        // job alone, always a separate deliberate act. Ceiling: .stopped also covers a
                        // dead battery or walking out of range, so those get the fast switch too — same
                        // desired outcome, so harmless; a real HingeState replaces this proxy outright.
                        if state == .stopped, self.manualSource == "auto", self.source == "glasses" {
                            self.fallbackTask?.cancel()
                            await self.switchTo(glasses: false)
                        }
                    }
                })
                tokens.append(session.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        self?.glassesState = "session error: \(error.description)"
                        if error == .datAppOnTheGlassesUpdateRequired { try? await Wearables.shared.openDATGlassesAppUpdate() }
                    }
                })
                try session.start()

                // Wait until the device link is up; addCamera returns nil before that.
                tries = 0
                while session.state != .started, tries < 60 {           // ponytail: 30 s ceiling
                    if session.state == .stopped {                        // "Device unavailable" (SDK #292) usually clears on retry
                        self.session = nil; tokens.removeAll()
                        if attempt < 3 {
                            glassesState = "glasses refused, retrying (\(attempt + 1)/3)…"
                            try await Task.sleep(for: .seconds(2))
                            startGlasses(resolution: resolution, fps: fps, attempt: attempt + 1)
                        } else {
                            glassesOn = false
                        }
                        return
                    }
                    try await Task.sleep(for: .milliseconds(500)); tries += 1
                }
                guard session.state == .started else {
                    glassesState = "session never reached started (\(session.state.description))"
                    glassesOn = false
                    return
                }

                // hvc1 = compressed HEVC, keeps delivering while the app is in the background.
                let res: StreamingResolution = resolution == "low" ? .low : resolution == "medium" ? .medium : .high
                let config = StreamConfiguration(videoCodec: .hvc1, resolution: res, frameRate: fps)
                guard let camera = try session.addCamera(config: config) else {
                    glassesState = "addCamera returned nil"
                    glassesOn = false
                    return
                }
                self.camera = camera

                tokens.append(camera.stream.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        self.glassesState = "stream \(state)"
                        self.glassesStreaming = (state == .streaming)
                        self.evaluateSource()
                    }
                })
                tokens.append(camera.stream.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.glassesState = "stream error: \(error.description)"
                        self.glassesStreaming = false
                        self.evaluateSource()
                    }
                })
                let hot = self.hot, up = self.uplink
                tokens.append(camera.stream.videoFramePublisher.listen { frame in
                    // Runs on the SDK's thread. No main-actor hop: nothing here touches SwiftUI state.
                    let sb = frame.sampleBuffer
                    hot.frames += 1
                    hot.bytes += CMSampleBufferGetTotalSampleSize(sb)
                    if hot.forward, hot.live || hot.warm {
                        hot.sent += 1
                        if let t = hot.transcoder { t.decode(sb) }            // H.264 mode: decode → mixer → encoder
                        else if hot.live { Task { await up.append(sb) } }     // HEVC mode: passthrough, no encode
                    }
                    if !hot.showMixerVideo, let preview = hot.preview {       // AVSampleBufferDisplayLayer is thread-safe
                        if preview.status == .failed { preview.flush() }
                        preview.enqueue(sb)                                   // layer decodes HEVC itself
                    }
                })
                tokens.append(camera.stream.photoDataPublisher.listen { [weak self] photo in
                    Task { @MainActor in
                        if let img = UIImage(data: photo.data) {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            self?.lastPhotoAt = Date()
                        }
                    }
                })
                camera.stream.start()
            } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
                glassesState = "glasses need the Meta app update, opening Meta AI"
                glassesOn = false
                try? await Wearables.shared.openDATGlassesAppUpdate()
            } catch {
                glassesState = error.localizedDescription
                glassesOn = false
            }
        }
    }

    func stopGlasses() {
        camera?.stream.stop()
        camera?.stop()
        session?.stop()
        camera = nil
        session = nil
        tokens.removeAll()
        glassesStreaming = false
        glassesOn = false
        glassesState = "stopped"
        evaluateSource()
    }

    func capturePhoto() {
        _ = camera?.stream.capturePhoto(format: .jpeg)
    }

    // MARK: fallback camera (StreamHand-style: glasses drop → phone camera, glasses back → glasses)

    /// "auto" = glasses with automatic phone fallback; "glasses" = force glasses; "back"/"front" = force a phone camera.
    func setSource(_ s: String) {
        manualSource = s
        if s == "back" || s == "front" { fallbackPosition = s == "front" ? .front : .back }
        evaluateSource()
    }

    private func evaluateSource() {
        fallbackTask?.cancel()
        switch manualSource {
        case "back", "front":
            Task { await switchTo(glasses: false) }     // re-attaching with the other position swaps cameras
            return
        case "glasses":
            if source == "phone" { Task { await switchTo(glasses: true) } }
            return
        default: break
        }
        if glassesStreaming {
            if source == "phone" { Task { await switchTo(glasses: true) } }
        } else if source == "glasses" {
            fallbackTask = Task { [weak self] in        // ponytail: 2 s debounce, no hysteresis
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, !self.glassesStreaming else { return }
                await self.switchTo(glasses: false)
            }
        }
    }

    private func switchTo(glasses: Bool) async {
        do {
            if glasses {
                try await mixer.attachVideo(nil)
                source = "glasses"
                cameraDevice = nil
                cameraCapabilities = nil
            } else {
                // Encoded by HaishinKit in whatever geometry goLive fixed for this session, so the outgoing
                // stream never changes format even when the source switches. Phone capture pauses in the
                // background; glasses HEVC doesn't.
                // Re-read fresh on every attach (not cached) so a front/back switch re-picks the lens and
                // re-runs every capability check against the NEW device -- see CameraSettings.apply's doc.
                let camSettings = CameraSettings.loadFromDefaults()
                let cam = CameraSettings.device(lens: camSettings.lens, position: fallbackPosition)
                await wireMixer()
                await mixer.setSessionPreset(phoneQuality.sessionPreset)
                let mode = Self.stabilizationMode(phoneQuality.stabilization)
                try await mixer.attachVideo(cam, track: 0) { unit in
                    unit.preferredVideoStabilizationMode = mode
                    unit.isVideoMirrored = camSettings.mirrored
                    if let device = unit.device {
                        CameraSettings.apply(camSettings, to: device)
                    }
                }
                if mode != .off { applog("stream", "stabilization requested: \(phoneQuality.stabilization)") }
                applog("stream", "camera lens=\(camSettings.lens) position=\(fallbackPosition == .front ? "front" : "back")")
                // ponytail: re-acquire rather than reuse `cam`. Swift 6 region isolation treats `cam` as
                // sent once it crosses into the mixer's domain, so touching it again here is a data race by
                // construction. AVCaptureDevice.default returns the same underlying device anyway.
                cameraDevice = CameraSettings.device(lens: camSettings.lens, position: fallbackPosition)
                cameraCapabilities = CameraCapabilities.probe(lens: camSettings.lens, position: fallbackPosition)
                cameraPosition = fallbackPosition
                try? await mixer.setFrameRate(Float64(phoneQuality.fps))
                await mixer.setVideoOrientation(phoneQuality.landscape ? .landscapeRight : .portrait)
                source = "phone"
            }
        } catch {
            rtmpState = "camera switch: \(error.localizedDescription)"
        }
    }

    // MARK: live camera controls (phone only -- see cameraDevice's doc)

    /// Re-applies every phone camera setting to the already-attached device via lockForConfiguration(),
    /// instead of re-attaching -- see cameraDevice's doc above. Bound to every live slider's onChange, not
    /// debounced: SwiftUI already delivers those at ~display rate, so calling this on every one already
    /// reads as immediate (this is the Camera app's own feel -- the picture changes under your finger while
    /// dragging, not on release), and a timer-based coalesce on top would only be felt as lag. `log: false`
    /// is the one concession -- see CameraSettings.apply's doc -- and costs nothing in device writes.
    func applyCameraSettings() {
        guard let device = cameraDevice else { return }
        CameraSettings.apply(CameraSettings.loadFromDefaults(), to: device, log: false)
    }

    /// Lens is a different physical AVCaptureDevice, not a settable property on the one we're holding (see
    /// CameraSettings' type doc) -- switching it re-attaches the phone camera through the normal switchTo
    /// path, same mechanism as a front/back switch. A brief reattach glitch is fine for a discrete tap (the
    /// Camera app's own lens switch isn't seamless either); applyCameraSettings() above exists specifically
    /// so the continuous sliders never have to pay that cost per tick.
    func switchLens(_ lens: String) {
        guard source == "phone" else { return }
        UserDefaults.standard.set(lens, forKey: "camLens")
        Task { await switchTo(glasses: false) }
    }

    /// Live stabilisation switch -- deliberately a re-attach, same mechanism as switchLens above, not a
    /// live tweak on the existing connection. VideoDeviceUnit (where preferredVideoStabilizationMode
    /// actually lives -- see switchTo's attachVideo configuration closure) only exists inside that closure,
    /// isolated to the mixer actor; Streamer only keeps the plain AVCaptureDevice handle afterward (see
    /// cameraDevice's doc), by design, for Swift 6 region-isolation safety (see switchTo's re-acquire
    /// comment -- that's the exact rule that broke the last build here). This HaishinKit version (2.1.0+)
    /// exposes no confirmed way to reach a live VideoDeviceUnit again post-attach (unverifiable without a
    /// build here), so this reattaches through switchTo(glasses:) instead. The framing jump this causes is
    /// expected anyway -- each stabilisation mode crops differently -- so the extra reattach glitch costs
    /// little more.
    func setStabilization(_ mode: String) {
        guard source == "phone" else { return }
        UserDefaults.standard.set(mode, forKey: "phoneStabilization")
        phoneQuality.stabilization = mode
        Task { await switchTo(glasses: false) }
    }

    /// Live mirror toggle -- same reattach reasoning as setStabilization above: isVideoMirrored also only
    /// lives on VideoDeviceUnit, set once in switchTo's attachVideo configuration closure. camMirrored is
    /// already read fresh every attach via CameraSettings.loadFromDefaults(), so writing the key and
    /// reattaching is the whole implementation.
    func setMirrored(_ mirrored: Bool) {
        guard source == "phone" else { return }
        UserDefaults.standard.set(mirrored, forKey: "camMirrored")
        Task { await switchTo(glasses: false) }
    }

    /// Long-press AE/AF lock: freezes focus and exposure at whatever they've already converged to
    /// (`.locked` mode), independently gated per Apple's docs same as tapToFocus below. Off restores the
    /// same continuous auto modes tapToFocus uses -- not whatever manual focus/exposure Settings say -- so
    /// a second long-press reads as "un-jam", not a surprise mode switch.
    /// ponytail: a reattach elsewhere (lens/stabilisation/mirror switch, or the fallback camera changing)
    /// resets focus/exposure back to CameraSettings' own modes without telling this lock go stale --
    /// ContentView clears its badge on a source change but not on an in-place reattach; add a
    /// Streamer-side published lock flag if that combination turns out to matter in practice.
    func setAEAFLocked(_ locked: Bool) {
        guard let device = cameraDevice else { return }
        do { try device.lockForConfiguration() } catch {
            applog("stream", "AE/AF lock: lockForConfiguration failed: \(error.localizedDescription)", error: true)
            return
        }
        defer { device.unlockForConfiguration() }
        if locked {
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            applog("stream", "AE/AF lock engaged")
        } else {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            applog("stream", "AE/AF lock released")
        }
    }

    /// Live "lock" reads whatever continuous auto white balance has already converged to right now and
    /// freezes there -- more useful mid-walk than picking a Kelvin value blind (see CameraSettings' type
    /// doc). Converts the sampled gains back to temperature/tint (temperatureAndTintValues(for:) is
    /// deviceWhiteBalanceGains(for:)'s documented inverse -- that forward direction is already used in
    /// CameraSettings.apply above) and writes through the exact camWBTemperature/camWBTint/
    /// camWhiteBalanceManual keys Settings' numeric fields use -- one source of truth, not a second
    /// locked-gains key -- then reapplies through the normal coalesced path. CameraSettings.apply()
    /// recomputes gains FROM those written values, which round-trips to (imperceptibly) the same lock
    /// rather than the exact gains sampled here; that's the trade for reusing one apply path instead of a
    /// bespoke lockForConfiguration call here too.
    func setWhiteBalanceLocked(_ locked: Bool) {
        let d = UserDefaults.standard
        if locked, let device = cameraDevice, device.isWhiteBalanceModeSupported(.locked) {
            let tt = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            d.set(Double(tt.temperature), forKey: "camWBTemperature")
            d.set(Double(tt.tint), forKey: "camWBTint")
            d.set(true, forKey: "camWhiteBalanceManual")
        } else {
            d.set(false, forKey: "camWhiteBalanceManual")
        }
        applyCameraSettings()
    }

    /// Tap-to-focus/expose: independently gated on hardware support (isFocusPointOfInterestSupported /
    /// isExposurePointOfInterestSupported, per Apple's docs), continuous mode at the tapped point rather
    /// than one-shot .autoFocus/.autoExpose -- simpler than AVCam's subjectAreaDidChange-revert-to-center
    /// dance, same practical result (refocus where you tapped, keep tracking from there).
    /// ponytail: no revert-to-center on scene change; add an
    /// AVCaptureDevice.subjectAreaDidChangeNotification observer if a tap that's now stale (subject walked
    /// off) turns out to matter in practice.
    /// `point` must already be in AVCaptureDevice's point-of-interest space -- see
    /// CameraSettings.devicePoint(forViewPoint:orientation:mirrored:), the pure conversion from a preview tap.
    func tapToFocus(at point: CGPoint) {
        guard let device = cameraDevice else { return }
        do { try device.lockForConfiguration() } catch {
            applog("stream", "tap focus: lockForConfiguration failed: \(error.localizedDescription)", error: true)
            return
        }
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusPointOfInterest = point
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = point
            device.exposureMode = .continuousAutoExposure
        }
        applog("stream", "tap focus/expose at \(String(format: "%.2f,%.2f", point.x, point.y))")
    }

    // MARK: audio inputs

    /// Lists inputs for the Settings picker. Called on demand (Settings opens, Go Live), never from route-change
    /// notifications: switching category fires those and looped forever.
    func refreshMics() {
        let s = AVAudioSession.sharedInstance()
        let wasPlayback = s.category == .playback
        // allowBluetoothHFP is what makes the glasses show up as an input; inputs are only listed under a record category.
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        let list = (s.availableInputs ?? []).map { Mic(id: $0.uid, name: $0.portName) }
        if wasPlayback && !live { try? s.setCategory(.playback, mode: .moviePlayback, options: []) }
        guard list != mics else { return }
        mics = list
        applog("stream", "mics: \(mics.map(\.name))")
    }

    /// Camera off = detach any phone camera, stop forwarding glasses frames, and push black frames at 15 fps
    /// so the platform keeps a live video track instead of freezing on the last picture.
    func setCameraOff(_ off: Bool) {
        cameraOff = off
        applog("stream", "cameraOff=\(off)")
        blackTask?.cancel(); blackTask = nil
        guard off else { evaluateSource(); return }
        cameraDevice = nil
        cameraCapabilities = nil
        Task { try? await mixer.attachVideo(nil) }
        blackTask = Task { [weak self] in
            guard let pb = Self.blackPixelBuffer() else { return }
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
            guard let fd else { return }
            while !Task.isCancelled, let self, self.live, self.cameraOff {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
                                                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                                decodeTimeStamp: .invalid)
                var sb: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
                if let sb { await self.mixer.append(sb) }        // goes through HaishinKit's encoder like the phone camera
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    /// Rewrites a decoded glasses frame's timestamp onto the phone's own host clock before it reaches the
    /// mixer -- fixes the blur+glasses freeze (appended kept climbing, nothing came out; see mixerOut above).
    ///
    /// Checked directly in HaishinKit 2.1.0 and 2.2.5 source (Mixer/MediaMixer.swift, Screen/Screen.swift):
    /// mixer.append() always reaches Screen.append() -- track input is fed into Screen unconditionally in
    /// 2.1.0, and gated only on videoMixerSettings.mode == .offscreen (which blur sets) in 2.2.5, not on the
    /// source of the frame -- so glasses frames DO arrive at the screen either way. What actually renders
    /// them out, though, is a private displayLink loop MediaMixer starts itself: setVideoMixerSettings(_:)
    /// calls its own private setVideoRenderingMode(mode) whenever mode changes (also once from
    /// startRunning()), which is exactly what syncBlurEffect() below already triggers by flipping
    /// videoMixerSettings.mode to .offscreen -- there is no public setVideoRenderingMode to call ourselves,
    /// and the mixer already calls it. That part of a prior hypothesis for this bug does not hold up against
    /// the source and was not the fix applied here.
    ///
    /// What that private loop's Screen.makeSampleBuffer does, every displayLink tick, is reject any frame
    /// whose computed presentationTimeStamp doesn't advance past the last one it rendered -- and it computes
    /// that from the offscreen canvas's own track's sample buffer PTS compared against the displayLink's
    /// host-clock timestamp (Screen's videoCaptureLatency/targetTimestamp bookkeeping). The phone camera's
    /// CMSampleBuffers are already host-clock timestamped by AVFoundation, so that comparison is sound and
    /// blur-while-on-phone-camera renders fine (per the report: front/back camera both produce output, only
    /// back camera's fps is the separate, expected Vision-cost issue below). The glasses' CMSampleBuffers
    /// come from Meta's Wearables SDK over Bluetooth with no documented guarantee their PTS is on that same
    /// clock -- MWDATCamera is closed-source, so this is the one link in the chain not directly verifiable --
    /// and Transcoder.decode() (see Transcoder.swift, not touched here) carries that original PTS straight
    /// through the decode. A source clock that doesn't line up with the displayLink's would make the
    /// monotonic-PTS guard fail forever once it drifts behind, which matches "appended climbs, nothing comes
    /// out" exactly and explains why only the glasses path (not the phone camera, same offscreen renderer)
    /// freezes. Stamping "now" on the host clock here -- the same clock the black-frame generator below
    /// already uses, and the one AVFoundation already uses for the phone camera -- makes every source the
    /// mixer ever sees carry a PTS in that one clock domain, which is what the renderer's guard assumes.
    /// nonisolated: called synchronously from Transcoder's @Sendable sink closure (VTDecompressionSession's
    /// callback thread, not the main actor) -- a plain (implicitly MainActor) static func here would not
    /// compile without an await it cannot afford on that thread.
    nonisolated private static func retimestamped(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let imageBuffer = sb.imageBuffer, let fd = sb.formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: sb.duration,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: imageBuffer, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }

    private static func blackPixelBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 720, 1280, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    func setMuted(_ on: Bool) {
        muted = on
        applog("stream", "muted=\(on)")
        Task {   // ponytail: mute = detach the mic; AudioMixerSettings per-track flags avoided
            try? await mixer.attachAudio(on ? nil : AVCaptureDevice.default(for: .audio))
        }
    }

    // MARK: RTMP

    /// bitrateKbps applies to what HaishinKit encodes (phone camera, black frames); the glasses set their own HEVC bitrate.
    /// codec: "hevc" passes the glasses' stream through untouched (YouTube, Restream, own relay);
    /// "h264" decodes and re-encodes on the phone (Kick, Twitch without Affiliate). Phone-camera video follows the same choice.
    func goLive(url: String, key: String, micUID: String, fallbackPosition: AVCaptureDevice.Position, bitrateKbps: Int = 4000, codec: String = "hevc", srtLatencyMs: Int = 2000, quality: PhoneQuality = .init()) {
        // Scheme picks the transport: srt:// goes out over SRT, everything else over RTMP(S).
        // Rebuilt per session so switching ingest between streams doesn't need an app restart.
        phoneQuality = quality
        let url = Self.withSRTLatency(url, ms: srtLatencyMs)
        uplink = Uplink.make(for: url)
        applog("stream", "uplink = \(uplink.isSRT ? "srt" : "rtmp")")
        // An explicit camera pick from the source picker outranks the Settings fallback preference:
        // that setting only says which camera to fall back TO when the glasses drop, so applying it
        // here was silently flipping a deliberate "back camera" choice to front on GO LIVE.
        if manualSource != "back", manualSource != "front" { self.fallbackPosition = fallbackPosition }
        let h264 = codec == "h264"
        // ponytail: adaptive bitrate's real gate is phoneEncodes ("is the phone doing the encoding"), not
        // codec == h264 — h264 always means the phone encodes, but so does hevc with the phone camera
        // driving video (source == "phone") or black frames (cameraOff). The one case with no knob is hevc
        // GLASSES PASSTHROUGH: the glasses pick their own HEVC bitrate (measured 450-600 kbps) and the phone
        // never re-encodes that video, so there's nothing to turn down. There's no headroom either — a link
        // that can't carry 600 kbps can't carry a transcode, since "helping" would mean targeting below
        // ~500 kbps, and 720x1280 at that rate is unwatchable. Do NOT auto-switch passthrough -> transcode
        // as a survival mode either: transcode needs the mixer pipeline, which silently re-imposes the PiP
        // requirement for background streaming — the streamer pockets the phone, the stream dies, and
        // nothing here tells them why.
        hot.transcoder?.invalidate()
        currentBitrateKbps = bitrateKbps          // HUD baseline; moves once phoneEncodes goes true
        bitrateCeilingKbps = bitrateKbps
        thermalCeilingKbps = nil
        cleanTicks = 0
        lastBitrateAdjustAt = nil
        hot.congested = false; hot.queueBytesOut = 0; hot.bytesOutPerSecond = 0
        // Installed regardless of codec: harmless telemetry-only capture (see QueueWatcher) even on a
        // session where phoneEncodes never goes true, and source/cameraOff can flip phoneEncodes mid-session
        // (glasses -> phone fallback) independent of the codec picked here.
        Task { [up = uplink] in await up.setBitRateStrategy(QueueWatcher(hot: hot)) }
        transcoding = h264
        if h264 {
            let mixer = self.mixer, hot = self.hot
            // Warm-up decodes to get the decoder synced to a keyframe, but nothing reaches the encoder until
            // publishing: video arriving before the publish handshake completes makes ingests drop the connection.
            // Blur (if enabled) happens once, in the mixer via syncBlurEffect() below -- not here anymore,
            // so decoded frames are never pixellated twice.
            hot.transcoder = Transcoder { sb in
                guard hot.live else { return }
                hot.appended += 1
                guard let sb = Self.retimestamped(sb) else { return }
                Task { await mixer.append(sb) }
            }
        } else {
            hot.transcoder = nil
        }

        // New session: reset the downtime/drop counters. liveSince is set once, below, on the first successful
        // connect, and is deliberately NOT reset by a reconnect — a session (GO LIVE → END LIVE) survives drops.
        downtime = 0; drops = 0; connectedSince = nil; sessionSummary = nil
        downSince = nil; escalated2m = false; escalated5m = false; backoff = 1; blurHidCamera = false
        sessionGeometryFixed = false
        warnedPhoneBattery = false; warnedThermal = false; warnedGlassesThermal = false
        startHealthMonitoring()
        reconnectTask?.cancel()

        reconnectTask = Task {
            do {
                // Meta docs: audio route must be settled before frames flow; do this before connect.
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                if let port = audioSession.availableInputs?.first(where: { $0.uid == micUID }) {
                    try audioSession.setPreferredInput(port)
                }
                try audioSession.setActive(true)

                if !muted { try await mixer.attachAudio(AVCaptureDevice.default(for: .audio)) }
                await wireMixer()

                // profileLevel containing "HEVC" flips HaishinKit's internal format to .hevc (onMetaData codec id);
                // the encoder handles phone-camera video, black frames and, in H.264 mode, the decoded glasses frames.
                // Geometry is fixed for the session: changing frame size mid-stream breaks players.
                // Glasses dictate 720x1280 at 30; the phone camera uses whatever the user configured. Gate on the
                // ACTUAL active source (`source`), not the manual preference (`manualSource`): "auto" can already
                // be sitting on the phone camera (glasses not streaming yet, or already fell back) by the time GO
                // LIVE is pressed, and manualSource == "auto" doesn't say which -- gating on manualSource silently
                // locked an auto-fallback phone session into glasses' 720x1280@30 and dropped the user's configured
                // quality (1080p60, say) any time the source pill read auto.
                let onPhone = source == "phone"
                let size = onPhone ? phoneQuality.size : Self.glassesSize
                let rate = onPhone ? phoneQuality.fps : 30
                sessionVideoSize = size
                sessionGeometryFixed = true
                applog("stream", "encoder \(Int(size.width))x\(Int(size.height)) @\(rate) (\(onPhone ? "phone" : "glasses"))")
                await uplink.setVideoSettings(VideoCodecSettings(
                    videoSize: size,
                    bitRate: bitrateKbps * 1000,
                    profileLevel: (h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
                    maxKeyFrameIntervalDuration: 2,
                    expectedFrameRate: Float64(rate)))
                if h264 {                                 // decoded frames need the mixer → encoder → stream path
                    await wireMixer()
                    // Force the render loop off before resizing, regardless of whether stopLive()'s own
                    // teardown Task has finished yet -- goLive() must not trust that timing (see
                    // setScreenSize's doc). No-op if it's already off (the common case: blur was never on).
                    await setOffscreenMode(false)
                    await Self.setScreenSize(mixer, to: size)   // offscreen rendering (blur) must output the geometry fixed above
                    var vm = await mixer.videoMixerSettings
                    vm.mainTrack = 0                       // track 0 straight through to the encoder
                    await mixer.setVideoMixerSettings(vm)
                    await syncBlurEffect()                 // registers blur + switches to .offscreen if already enabled
                    hot.warm = true
                    syncHot()                              // glasses+blur: preview switches to the (blurred) mixer output now that decode is starting
                    if onPhone {
                        // The transcoder only ever decodes GLASSES frames (see the videoFramePublisher
                        // listener in startGlasses(), the only place that calls Transcoder.decode()) -- with
                        // the phone camera driving video there is nothing to warm up and hot.transcoder.decoded
                        // can never leave 0, so this used to burn the full 8s ceiling below on every
                        // phone-camera h264 session for nothing, delaying GO LIVE by that much every time.
                        applog("stream", "phone camera driving video -- skipping decoder warm-up")
                    } else {
                        // Decode before connecting: an ingest that finds no video in its first seconds of
                        // probing treats the whole session as audio-only. Warm up, then connect with frames
                        // already flowing.
                        rtmpState = "syncing decoder…"
                        var waited = 0
                        while hot.transcoder?.decoded == 0, waited < 80 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
                        applog("stream", "decoder warm after \(waited * 100) ms, decoded=\(hot.transcoder?.decoded ?? 0)")
                    }
                }
                await uplink.setAudioSettings(AudioCodecSettings(bitRate: 96_000))

                applog("stream", "connecting to \(url) key=\(key.count) chars, mic=\(micUID.isEmpty ? "default" : micUID), bitrate=\(bitrateKbps), codec=\(codec)")
                Task { await Self.netProbe(url) }        // logs which interface iOS picks and whether the host answers on it
                Task { [up = uplink] in await up.logStatus() }   // RTMP server status lines; no-op on SRT

                await superviseConnection(url: url, key: key)
            } catch {
                applog("stream", "goLive setup failed: \(String(describing: error))", error: true)
                rtmpState = error.localizedDescription
                Task { [up = uplink] in await up.close() }   // drop a half-open socket so the next attempt starts clean
            }
        }
    }

    // MARK: adaptive bitrate control

    /// Called once a second from the stats loop above. Runs whenever phoneEncodes is true (h264 transcode,
    /// or hevc with the phone driving video) — a no-op for hevc glasses passthrough, the one path with no
    /// knob (see goLive's gate comment). Reads QueueWatcher's telemetry off `hot`, decides, and applies; the
    /// network signal is real (HaishinKit's own NetworkMonitor via StreamBitRateStrategy), the decision loop
    /// is ours, so it stays in lockstep with the existing 1s tick instead of a second timer.
    private func adaptBitrate() async {
        guard phoneEncodes, live else { return }
        if hot.congested {
            hot.congested = false
            cleanTicks = 0
            await stepBitrate(up: false, reason: "queue backlog")
            return
        }
        let throughputKbps = hot.bytesOutPerSecond * 8 / 1000
        if throughputKbps < currentBitrateKbps * 7 / 10 {   // short of target by 30%+
            cleanTicks = 0
            await stepBitrate(up: false, reason: "throughput \(throughputKbps)kbps < target \(currentBitrateKbps)kbps")
            return
        }
        cleanTicks += 1
        if cleanTicks >= 15 {
            cleanTicks = 0
            await stepBitrate(up: true, reason: "15s clean")
        }
    }

    /// Applies one AIMD step and logs the ladder (Settings → Logs shows it after a walk). Rate-limited so
    /// congestion + thermal firing together still yields at most one change per bitrateAdjustCooldown.
    private func stepBitrate(up: Bool, reason: String) async {
        if let last = lastBitrateAdjustAt, Date().timeIntervalSince(last) < bitrateAdjustCooldown { return }
        let ceiling = min(thermalCeilingKbps ?? bitrateCeilingKbps, bitrateCeilingKbps)
        let next = Self.steppedBitrate(current: currentBitrateKbps, up: up, ceilingKbps: max(ceiling, bitrateFloorKbps), floorKbps: bitrateFloorKbps)
        guard next != currentBitrateKbps else { return }
        var vs = await uplink.videoSettings
        vs.bitRate = next * 1000
        await uplink.setVideoSettings(vs)
        currentBitrateKbps = next
        lastBitrateAdjustAt = Date()
        applog("stream", "bitrate \(up ? "up" : "down") -> \(next) kbps (\(reason))")
    }

    /// Keeps the mixer's blur effect registration and rendering mode in sync with Privacy.enabled. Privacy
    /// exposes `enabled` as a plain var that ContentView sets directly (see ContentView's blur toggle) with
    /// no delegate back to Streamer, so this is polled from the 1s stats tick; goLive()'s h264 setup also
    /// calls it once up front so a session that starts with blur already on doesn't wait a full tick for its
    /// first frames to be covered. stopLive() forces the off path unconditionally (see setOffscreenMode)
    /// so a session that ends with blur on can't leave the render loop running into the next one.
    ///
    /// registerVideoEffect hooks mixer.screen (HaishinKit's offscreen render object, track 0 by default) --
    /// checked HaishinKit 2.1.0 and 2.2.5 source directly: that's the one place phone camera, black frames
    /// and (in H.264 mode) decoded glasses frames all pass through once the mixer is in .offscreen mode --
    /// 2.1.0 feeds Screen from every mixer.append/attachVideo call unconditionally, 2.2.5 gates that same
    /// feed on videoMixerSettings.mode already being .offscreen (checked both directly; this call always sets
    /// mode before frames need to arrive, so the ordering holds either way). .passthrough skips
    /// Screen/VideoTrackScreenObject rendering entirely and forwards raw buffers straight to the encoder,
    /// which is why blur silently did nothing before this. Offscreen costs more (an extra render pass), so
    /// it's only switched on while blur is actually enabled. See retimestamped() near blackPixelBuffer()
    /// above for the offscreen-mode freeze this uncovered on the glasses path specifically, and what fixed it.
    /// `Screen` lives on HaishinKit's own global actor, so its size can't be assigned from the main actor.
    /// What the offscreen canvas should be right now: the session's fixed geometry while live, otherwise
    /// whatever the phone camera is configured to produce, since that is the only thing the mixer renders
    /// before GO LIVE.
    private var blurCanvasSize: CGSize {
        sessionGeometryFixed ? sessionVideoSize : phoneQuality.size
    }

    /// Screen.size reallocates the offscreen pixel-buffer pool (checked Screen.swift 2.1.0/2.2.5 directly --
    /// the `size` didSet calls CVPixelBufferPoolCreate unconditionally, no lock). The only consumer reading
    /// that pool is HaishinKit's own offscreen render loop: a Task MediaMixer spawns on this same ScreenActor
    /// from setVideoRenderingMode(.offscreen) that runs until displayLink.stopRunning() ends its AsyncStream --
    /// checked both tags directly, that's the ONLY public lever that stops it, and MediaMixer never calls it
    /// itself. So this must only run once that loop is confirmed stopped, not merely "before blur is next
    /// turned on". Getting that backwards is the relive crash (vImageCopyBuffer, the offscreen CPU renderer's
    /// only call site in either tag -- grepped both -- reached from a Task closure, matching the decoded
    /// report exactly): stopLive() used to leave mode == .offscreen whenever a session ended with blur on,
    /// so the next goLive() resized Screen.size while that session's render loop Task was still alive on this
    /// same actor. Callers rely on actor FIFO ordering: awaiting setOffscreenMode(false) first enqueues the
    /// stop on this actor ahead of the resize enqueued right after, so by the time this runs the loop has
    /// already exited -- the same ordering assumption HaishinKit's own syncBlurEffect-adjacent calls already
    /// relied on before this fix, just never stated. Not verified on-device (no build/run available here).
    @ScreenActor private static func setScreenSize(_ mixer: MediaMixer, to size: CGSize) {
        mixer.screen.size = size
    }

    /// The one place that registers/unregisters the blur effect and flips videoMixerSettings.mode -- goLive(),
    /// stopLive() and the 1s tick (via syncBlurEffect below) all route through this instead of touching
    /// mixer.screen/videoMixerSettings directly, so there is one well-defined order instead of three callers
    /// mutating the same state independently (which is what let stopLive() and goLive() disagree about
    /// whether the render loop was still running -- see setScreenSize's doc). Idempotent on blurEffectActive,
    /// so a redundant call (stopLive() forcing `false` when blur was never on, say) costs nothing.
    private func setOffscreenMode(_ on: Bool) async {
        guard let privacy, blurEffectActive != on else { return }
        blurEffectActive = on
        if on {
            _ = await mixer.screen.registerVideoEffect(privacy)
        } else {
            _ = await mixer.screen.unregisterVideoEffect(privacy)
        }
        var vm = await mixer.videoMixerSettings
        vm.mode = on ? .offscreen : .passthrough
        await mixer.setVideoMixerSettings(vm)   // starts/stops HaishinKit's offscreen render Task -- see setScreenSize's doc
        applog("stream", "privacy blur effect \(on ? "registered" : "unregistered"), mixer mode=\(vm.mode.rawValue)")
        syncHot()   // re-evaluate whether the glasses preview should now route through the (blurred) mixer output
    }

    private func syncBlurEffect() async {
        guard let privacy, privacy.enabled != blurEffectActive else { return }
        // Read once: `enabled` is a plain nonisolated(unsafe) var ContentView can flip mid-await, and the
        // resize below and the mode flip after it must agree on the same snapshot.
        let enabled = privacy.enabled
        if enabled {
            // Offscreen renders into Screen.size, which defaults to 1280x720 landscape. Without this a
            // portrait frame gets fitted into a landscape canvas and the picture shrinks to a stamp.
            // blurEffectActive is still false here (checked above), so the render loop is confirmed stopped
            // -- safe per setScreenSize's doc.
            await Self.setScreenSize(mixer, to: blurCanvasSize)
        }
        await setOffscreenMode(enabled)
    }

    /// Blur failing open is worse than no blur, because the streamer is trusting it. When detection stalls
    /// we hide the picture rather than publish frames we could not obscure, and say so out loud — silence
    /// would leave someone walking down a street believing faces were still being covered. Reuses the
    /// existing black-frame path, so the HUD honestly reads "cam off" for as long as it holds.
    private func checkBlurStall() {
        guard let privacy, privacy.enabled, live else { return }
        if privacy.stalled, !cameraOff {
            blurHidCamera = true
            setCameraOff(true)
            speaker?.speakSystem("blur stopped working, camera hidden")
            applog("stream", "privacy blur stalled - camera hidden", error: true)
        } else if !privacy.stalled, blurHidCamera {
            blurHidCamera = false
            setCameraOff(false)
            speaker?.speakSystem("blur working, camera back")
            applog("stream", "privacy blur recovered - camera back")
        }
    }

    /// Pure step: 20% down (floors at floorKbps), 10% up (ceilings at ceilingKbps). No I/O, no HaishinKit —
    /// the part worth unit-testing, exercised by Self.demo() below.
    static func steppedBitrate(current: Int, up: Bool, ceilingKbps: Int, floorKbps: Int) -> Int {
        let next = up ? current + current / 10 : current - current / 5
        return min(max(next, floorKbps), ceilingKbps)
    }

    /// Connects + publishes, retrying with exponential backoff (1, 2, 4, 8 s, capped at 15 s) on any failure.
    /// Covers the FIRST connect too — nothing here gives up, so a bad initial connect retries here instead of
    /// dying in goLive's catch. Runs until stopLive() cancels reconnectTask.
    private func superviseConnection(url: String, key: String) async {
        while !Task.isCancelled {
            do {
                try await connectWithTimeout(url)
                applog("stream", "connected, publishing")
                try await uplink.publish(key)

                let now = Date()
                connectedSince = now
                backoff = 1
                if let since = downSince {
                    if live {                                          // real recovery from a drop, not first connect
                        downtime += now.timeIntervalSince(since)
                        speaker?.stopRepeating(id: "rtmp", recovered: "stream back")
                        haptic(.success)
                    }
                    downSince = nil
                    escalated2m = false; escalated5m = false
                }
                rtmpState = "live"
                if !live {                                              // first-ever connect this session
                    live = true
                    liveSince = now
                    evaluateSource()
                }
            } catch {
                if Task.isCancelled { return }
                applog("stream", "connect failed: \(String(describing: error))", error: true)
                if live {
                    markDropped()
                } else {
                    if downSince == nil { downSince = Date() }          // clock starts even before ever connecting
                    rtmpState = error.localizedDescription               // surface the first-connect error
                }
                checkEscalation()
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
                continue
            }

            // ponytail: poll `connected` every 2 s instead of parsing RTMPConnection status codes for the drop
            // event — the status stream above is already logged separately for diagnostics.
            while !Task.isCancelled, await uplink.connected {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            markDropped()
        }
    }

    /// HaishinKit's own timeout doesn't always fire on a black-holed port; race the connect against a clock.
    private func connectWithTimeout(_ url: String) async throws {
        let up = uplink
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { try await up.connect(url) }
            g.addTask { try await Task.sleep(for: .seconds(12)); throw NSError(domain: "MetaStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not reach \(URL(string: url)?.host ?? url) within 12 s"]) }
            try await g.next()
            g.cancelAll()
        }
    }

    /// First sign a LIVE connection is down: starts the downtime clock, counts the drop, speaks + buzzes once.
    /// No-op if already marked — a failed reconnect attempt re-enters this after the poll loop already did.
    private func markDropped() {
        guard downSince == nil else { return }
        downSince = Date()
        drops += 1
        rtmpState = "reconnecting"
        applog("stream", "connection dropped, retrying", error: true)
        speaker?.startRepeating(id: "rtmp", text: "stream dropped")   // re-speaks itself at 30s/60s/2min
        haptic(.error)
    }

    /// Beyond Speaker's own 30s/60s/2min repeat cycle: one more nudge at 2 min down, another at 5 — so silence
    /// never stretches on forever. Covers a drop AND a stream that never connected in the first place.
    private func checkEscalation() {
        guard let since = downSince else { return }
        let elapsed = Date().timeIntervalSince(since)
        if elapsed >= 300, !escalated5m {
            escalated5m = true
            speaker?.speakSystem("stream still down after 5 minutes, may need a manual restart")
        } else if elapsed >= 120, !escalated2m {
            escalated2m = true
            speaker?.speakSystem("stream still down after 2 minutes")
        }
    }

    /// Backgrounded (screen off, glasses-only) haptics are a no-op anyway; skip the allocation.
    private func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard UIApplication.shared.applicationState == .active else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    // MARK: health monitoring

    /// Phone battery + thermal only matter while actually streaming (a 30-45 min walk is exactly when
    /// the phone throttles or the battery runs down), so they're only observed live → stopLive() rather
    /// than leaving isBatteryMonitoringEnabled and two NotificationCenter observers on for the app's life.
    private func startHealthMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updatePhoneBattery()
        thermal = ProcessInfo.processInfo.thermalState
        batteryObserver = NotificationCenter.default.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePhoneBattery() }
        }
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.thermal = ProcessInfo.processInfo.thermalState }
        }
        // ponytail: only picks up the glasses connected at the moment Go Live is pressed — matches the
        // file's documented usual order (start glasses, then go live). A glasses connect/reconnect mid-
        // stream won't retroactively start this stream; upgrade path is hooking it off session creation
        // in startGlasses() instead if that gap turns out to matter.
        if let id = session?.deviceId {
            glassesThermalTask = Task { [weak self] in
                for await state in Wearables.shared.deviceStateStream(for: id) {
                    self?.glassesThermal = state.thermalLevel
                }
            }
        }
    }

    private func stopHealthMonitoring() {
        if let o = batteryObserver { NotificationCenter.default.removeObserver(o) }
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        batteryObserver = nil; thermalObserver = nil
        UIDevice.current.isBatteryMonitoringEnabled = false
        glassesThermalTask?.cancel()
        glassesThermalTask = nil
        glassesThermal = nil
    }

    private func updatePhoneBattery() {
        let level = UIDevice.current.batteryLevel   // -1 while unknown/monitoring just turned on
        phoneBattery = level < 0 ? nil : Int(level * 100)
    }

    private func checkPhoneBattery() {
        guard let b = phoneBattery, b < 15, !warnedPhoneBattery else { return }
        warnedPhoneBattery = true
        speaker?.speakSystem("phone battery fifteen percent")
    }

    private func checkThermal() {
        // ThermalState isn't Comparable; rawValue order is nominal < fair < serious < critical.
        let serious = thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        // Heat and congestion both want less bitrate, and encoding is the expensive part — cap the ceiling
        // at wherever the AIMD loop is *after* one forced step down, so up-steps can't climb back until
        // thermal clears. Edge-triggered on thermalCeilingKbps == nil so this fires once per entry, not once
        // per tick. Gated on phoneEncodes, same as adaptBitrate — no knob to turn during hevc passthrough.
        if serious, thermalCeilingKbps == nil, phoneEncodes, live {
            thermalCeilingKbps = currentBitrateKbps   // close the edge-trigger now; refined once the drop lands
            Task {
                await self.stepBitrate(up: false, reason: "thermal \(self.thermal)")
                self.thermalCeilingKbps = self.currentBitrateKbps
            }
        } else if !serious {
            thermalCeilingKbps = nil
        }
        guard serious, !warnedThermal else { return }
        warnedThermal = true
        speaker?.speakSystem("phone getting hot")
    }

    /// ThermalLevel is Equatable, not Comparable/rawValue-ordered — switch on the cases the 0.9 docs list
    /// (unknown, none, light, moderate, severe, critical, emergency, shutdown) instead of guessing an order.
    private func checkGlassesThermal() {
        guard let t = glassesThermal, !warnedGlassesThermal else { return }
        switch t {
        case .severe, .critical, .emergency, .shutdown:
            warnedGlassesThermal = true
            speaker?.speakSystem("glasses getting hot")
        default: break
        }
    }

    func stopLive() {
        reconnectTask?.cancel()
        reconnectTask = nil
        sessionGeometryFixed = false   // idle previews size from the phone camera again, not the ended session
        if let since = downSince, live { downtime += Date().timeIntervalSince(since) }
        downSince = nil
        speaker?.stopRepeating(id: "rtmp")
        if let start = liveSince {
            let summary = "session \(Self.fmtClock(Date().timeIntervalSince(start))), \(Self.fmtClock(downtime)) down across \(drops) drops"
            sessionSummary = summary
            applog("stream", summary)
        }
        live = false
        liveSince = nil
        connectedSince = nil
        hot.warm = false
        hot.transcoder?.invalidate()
        hot.transcoder = nil
        syncHot()   // decode stopped: glasses preview (if that's what routed it) falls back to the raw HEVC feed
        currentBitrateKbps = 0
        thermalCeilingKbps = nil
        cleanTicks = 0
        lastBitrateAdjustAt = nil
        fallbackTask?.cancel()
        blackTask?.cancel(); blackTask = nil
        stopHealthMonitoring()
        rtmpState = "stopped"
        cameraDevice = nil
        cameraCapabilities = nil
        Task {
            // Force blur off unconditionally, even if the toggle is still on: a session that ends with it
            // on must not leave the offscreen render loop running into the next goLive() (see
            // setScreenSize's doc -- that loop is the one thing reading Screen.size, and the next session
            // resizes it). goLive() also forces this defensively, so this isn't the only thing standing
            // between the two sessions, but it stops the loop from spinning uselessly while idle either way.
            await setOffscreenMode(false)
            try? await mixer.attachVideo(nil)
            await uplink.close()
        }
        source = "glasses"
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])   // mic off, PiP stays armed
    }

    /// "m:ss" for the session summary, e.g. 1:48. Minutes aren't padded/capped — a long stream just reads "72:03".
    private static func fmtClock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: devices status line

    private func watchDevices(_ ids: [DeviceIdentifier]) {
        let list = ids.compactMap { Wearables.shared.deviceForIdentifier($0) }
        deviceTokens = list.flatMap { d in
            [d.addLinkStateListener { [weak self] _ in Task { @MainActor in self?.describeDevices() } },
             d.addCompatibilityListener { [weak self] _ in Task { @MainActor in self?.describeDevices() } }]
        }
        describeDevices()
    }

    private func describeDevices() {
        let list = Wearables.shared.devices.compactMap { Wearables.shared.deviceForIdentifier($0) }
            .map { "\($0.nameOrId()) \($0.linkState) \($0.compatibility())" }
        devices = list.isEmpty ? "none" : list.joined(separator: ", ")
    }

    /// Resumes a continuation at most once across competing callbacks.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Diagnostic: current network path + TCP reachability of the ingest host over the default route and over cellular only.
    private static func netProbe(_ urlString: String) async {
        guard let u = URL(string: urlString), let host = u.host else { return }
        let port = UInt16(u.port ?? (u.scheme == "rtmps" ? 443 : 1935))
        let path = await withCheckedContinuation { (c: CheckedContinuation<NWPath, Never>) in
            let m = NWPathMonitor(); m.pathUpdateHandler = { p in c.resume(returning: p); m.cancel() }; m.start(queue: .global())
        }
        let ifaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        applog("stream", "net path status=\(path.status) wifi=\(path.usesInterfaceType(.wifi)) cell=\(path.usesInterfaceType(.cellular)) expensive=\(path.isExpensive) ifaces=[\(ifaces)]")
        for (label, required) in [("default", nil), ("cellular", NWInterface.InterfaceType.cellular)] {
            let params = NWParameters.tcp
            if let required { params.requiredInterfaceType = required }
            let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: params)
            let result: String = await withCheckedContinuation { c in
                let once = Once()
                conn.stateUpdateHandler = { st in
                    switch st {
                    case .ready: if once.fire() { c.resume(returning: "ready via \(conn.currentPath?.availableInterfaces.first.map { "\($0.type)" } ?? "?")") }
                    case .failed(let e): if once.fire() { c.resume(returning: "failed: \(e)") }
                    case .waiting(let e): applog("stream", "probe \(label) waiting: \(e)")
                    default: break
                    }
                }
                conn.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + 6) { if once.fire() { c.resume(returning: "timeout 6 s") } }
            }
            conn.cancel()
            applog("stream", "probe \(label) \(host):\(port) -> \(result)", error: !result.hasPrefix("ready"))
        }
    }

    // Free Apple IDs get a "personal team"; its ID is only visible inside the signed app's provisioning profile.
    private static func readTeamID() -> String {
        let fallback = "unknown (not sideloaded yet)"
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: #"<key>TeamIdentifier</key>\s*<array>\s*<string>([A-Z0-9]+)</string>"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return fallback }
        return String(text[range])
    }
}

#if DEBUG
extension Streamer {
    /// Self-check for the pure AIMD step — no device, no HaishinKit.
    static func demo() {
        assert(steppedBitrate(current: 1000, up: false, ceilingKbps: 4000, floorKbps: 500) == 800, "down 20%")
        assert(steppedBitrate(current: 600, up: false, ceilingKbps: 4000, floorKbps: 500) == 500, "floors at 500")
        assert(steppedBitrate(current: 500, up: false, ceilingKbps: 4000, floorKbps: 500) == 500, "floor is a floor")
        assert(steppedBitrate(current: 500, up: true, ceilingKbps: 4000, floorKbps: 500) == 550, "up 10%")
        assert(steppedBitrate(current: 3900, up: true, ceilingKbps: 4000, floorKbps: 500) == 4000, "ceilings, no overshoot")
        assert(steppedBitrate(current: 4000, up: true, ceilingKbps: 4000, floorKbps: 500) == 4000, "ceiling is a ceiling")
        print("Streamer.demo() ok")
    }
}
#endif
