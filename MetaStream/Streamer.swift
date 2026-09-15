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
    var appended = 0                    // decoded frames handed to the mixer
    var showMixerVideo = false          // preview shows mixer output (phone camera / black) instead of glasses frames
    weak var preview: AVSampleBufferDisplayLayer?
}

/// Mirrors the mixer's video (phone camera, black frames) into the same preview layer the glasses use,
/// so one layer feeds the screen and Picture in Picture whatever the source is.
private final class LayerSink: MediaMixerOutput, @unchecked Sendable {
    private let hot: Hot
    init(hot: Hot) { self.hot = hot }
    var videoTrackId: UInt8? { 0 }
    var audioTrackId: UInt8? { nil }
    func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
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
        let show = source == "phone" || cameraOff
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

    private let hot = Hot()
    private lazy var sink = LayerSink(hot: hot)
    var pip: PiPController?                        // owned here so it outlives SwiftUI view rebuilds
    // ponytail: plain optional, not weak — Speaker never references Streamer, so no retain cycle. App.swift sets it once.
    var speaker: Speaker?
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

    private let connection = RTMPConnection()          // advertises hvc1 in the enhanced-RTMP connect by default
    private lazy var stream = RTMPStream(connection: connection)
    private let mixer = MediaMixer()
    private var mixerWired = false

    /// Phone-camera frames flow mixer → encoder → RTMP stream (and → preview view). Wired once, on first need.
    private func wireMixer() async {
        guard !mixerWired else { return }
        mixerWired = true
        await mixer.addOutput(stream)
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
                if self.live, tick % 5 == 0 {
                    let mode = self.hot.transcoder == nil ? "hevc-passthrough" : "h264-transcode"
                    applog("stream", "stats source=\(self.source) \(mode) glassesFps=\(self.fps) glassesKbps=\(self.kbps) sent=\(self.hot.sent) decoded=\(self.hot.transcoder?.decoded ?? 0) appended=\(self.hot.appended)")
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
                let hot = self.hot, rtmp = self.stream
                tokens.append(camera.stream.videoFramePublisher.listen { frame in
                    // Runs on the SDK's thread. No main-actor hop: nothing here touches SwiftUI state.
                    let sb = frame.sampleBuffer
                    hot.frames += 1
                    hot.bytes += CMSampleBufferGetTotalSampleSize(sb)
                    if hot.forward, hot.live || hot.warm {
                        hot.sent += 1
                        if let t = hot.transcoder { t.decode(sb) }            // H.264 mode: decode → mixer → encoder
                        else if hot.live { Task { await rtmp.append(sb) } }   // HEVC mode: passthrough, no encode
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
            } else {
                // Encoded by HaishinKit as HEVC 720x1280 (see setVideoSettings), same codec as the glasses,
                // so the RTMP stream never changes format. Phone capture pauses in background; glasses HEVC doesn't.
                let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: fallbackPosition)
                await wireMixer()
                try await mixer.attachVideo(cam)
                await mixer.setVideoOrientation(.portrait)
                source = "phone"
            }
        } catch {
            rtmpState = "camera switch: \(error.localizedDescription)"
        }
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
    func goLive(url: String, key: String, micUID: String, fallbackPosition: AVCaptureDevice.Position, bitrateKbps: Int = 4000, codec: String = "hevc") {
        self.fallbackPosition = fallbackPosition
        let h264 = codec == "h264"
        hot.transcoder?.invalidate()
        if h264 {
            let mixer = self.mixer, hot = self.hot
            // Warm-up decodes to get the decoder synced to a keyframe, but nothing reaches the encoder until
            // publishing: video arriving before the publish handshake completes makes ingests drop the connection.
            hot.transcoder = Transcoder { sb in
                guard hot.live else { return }
                hot.appended += 1
                Task { await mixer.append(sb) }
            }
        } else {
            hot.transcoder = nil
        }

        // New session: reset the downtime/drop counters. liveSince is set once, below, on the first successful
        // connect, and is deliberately NOT reset by a reconnect — a session (GO LIVE → END LIVE) survives drops.
        downtime = 0; drops = 0; connectedSince = nil; sessionSummary = nil
        downSince = nil; escalated2m = false; escalated5m = false; backoff = 1
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
                try? await stream.setVideoSettings(VideoCodecSettings(
                    videoSize: CGSize(width: 720, height: 1280),
                    bitRate: bitrateKbps * 1000,
                    profileLevel: (h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
                    maxKeyFrameIntervalDuration: 2,
                    expectedFrameRate: 30))
                if h264 {                                 // decoded frames need the mixer → encoder → stream path
                    await wireMixer()
                    var vm = await mixer.videoMixerSettings
                    vm.mode = .passthrough                // track 0 straight through to the encoder
                    vm.mainTrack = 0
                    await mixer.setVideoMixerSettings(vm)
                    // Decode before connecting: an ingest that finds no video in its first seconds of probing
                    // treats the whole session as audio-only. Warm up, then connect with frames already flowing.
                    hot.warm = true
                    rtmpState = "syncing decoder…"
                    var waited = 0
                    while hot.transcoder?.decoded == 0, waited < 80 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
                    applog("stream", "decoder warm after \(waited * 100) ms, decoded=\(hot.transcoder?.decoded ?? 0)")
                }
                try? await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000))

                applog("stream", "connecting to \(url) key=\(key.count) chars, mic=\(micUID.isEmpty ? "default" : micUID), bitrate=\(bitrateKbps), codec=\(codec)")
                Task { await Self.netProbe(url) }        // logs which interface iOS picks and whether the host answers on it
                Task { [connection] in                       // every NetConnection.* / NetStream.* status the server sends
                    for await st in await connection.status { applog("stream", "rtmp status: \(st.code) \(st.description)") }
                }

                await superviseConnection(url: url, key: key)
            } catch {
                applog("stream", "goLive setup failed: \(String(describing: error))", error: true)
                rtmpState = error.localizedDescription
                Task { try? await connection.close() }   // drop a half-open socket so the next attempt starts clean
            }
        }
    }

    /// Connects + publishes, retrying with exponential backoff (1, 2, 4, 8 s, capped at 15 s) on any failure.
    /// Covers the FIRST connect too — nothing here gives up, so a bad initial connect retries here instead of
    /// dying in goLive's catch. Runs until stopLive() cancels reconnectTask.
    private func superviseConnection(url: String, key: String) async {
        while !Task.isCancelled {
            do {
                try await connectWithTimeout(url)
                applog("stream", "connected, publishing")
                _ = try await stream.publish(key)

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
            while !Task.isCancelled, await connection.connected {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !Task.isCancelled else { return }
            markDropped()
        }
    }

    /// HaishinKit's own timeout doesn't always fire on a black-holed port; race the connect against a clock.
    private func connectWithTimeout(_ url: String) async throws {
        let conn = connection
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { _ = try await conn.connect(url) }
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
        guard thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, !warnedThermal else { return }
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
        fallbackTask?.cancel()
        blackTask?.cancel(); blackTask = nil
        stopHealthMonitoring()
        rtmpState = "stopped"
        Task {
            try? await mixer.attachVideo(nil)
            try? await connection.close()
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
