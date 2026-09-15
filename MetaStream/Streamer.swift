import Foundation
import Combine
import AVFoundation
import CoreMedia
import VideoToolbox
import UIKit
import MWDATCore
import MWDATCamera
import HaishinKit
import RTMPHaishinKit

struct Mic: Identifiable, Hashable { let id: String; let name: String }   // id = AVAudioSessionPortDescription.uid

@MainActor
final class Streamer: ObservableObject {
    @Published var registration = "unknown"
    @Published var glassesState = "idle"
    @Published var glassesOn = false
    @Published var rtmpState = "idle"
    @Published var frames = 0
    @Published var fps = 0
    @Published var kbps = 0
    @Published var teamID = "unknown (not sideloaded yet)"
    @Published var live = false
    @Published var liveSince: Date?
    @Published var devices = "none seen yet"
    @Published var source = "glasses"          // "glasses" | "phone" (what is actually going out right now)
    @Published var manualSource = "auto"       // "auto" | "glasses" | "back" | "front" (user's choice)
    @Published var mics: [Mic] = []
    @Published var muted = false
    @Published var lastPhotoAt: Date?

    /// Short glasses state for the HUD: "streaming" | "connecting" | "off".
    var glassesShort: String {
        let s = glassesState.lowercased()
        if s.contains("streaming") { return "streaming" }
        if ["starting", "looking", "waiting", "connecting", "session started"].contains(where: { s.contains($0) }) { return "connecting" }
        return "off"
    }

    // ponytail: ContentView sets this directly instead of a delegate protocol.
    weak var preview: AVSampleBufferDisplayLayer?

    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []        // SDK listeners die when their token is released
    private var deviceTokens: [any AnyListenerToken] = []  // per-device link/compat listeners
    private var glassesStreaming = false
    private var fallbackTask: Task<Void, Never>?
    private var fallbackPosition: AVCaptureDevice.Position = .back
    private var tickFrames = 0
    private var tickBytes = 0

    private let connection = RTMPConnection()          // advertises hvc1 in the enhanced-RTMP connect by default
    private lazy var stream = RTMPStream(connection: connection)
    private let mixer = MediaMixer()

    init() {
        teamID = Self.readTeamID()
        refreshMics()
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
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                self?.refreshMics()
            }
        }
        Task { [weak self] in                           // 1 s stats tick for the HUD
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.fps = self.tickFrames
                self.kbps = self.tickBytes * 8 / 1000
                self.tickFrames = 0
                self.tickBytes = 0
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
    func startGlasses(resolution: String = "high", fps: UInt = 30) {
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
                    Task { @MainActor in self?.glassesState = "session \(state.description)" }
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
                    if session.state == .stopped { glassesOn = false; return }   // error listener already reported why
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
                tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                    Task { @MainActor in
                        guard let self else { return }
                        self.frames += 1
                        self.tickFrames += 1
                        self.tickBytes += CMSampleBufferGetTotalSampleSize(frame.sampleBuffer)
                        if self.live && self.source == "glasses" {
                            Task { await self.stream.append(frame.sampleBuffer) }   // compressed → passthrough, no encode
                        }
                        if let preview = self.preview {
                            if preview.status == .failed { preview.flush() }
                            preview.enqueue(frame.sampleBuffer)                  // layer decodes HEVC itself
                        }
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
        guard live else { return }
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
                guard let self, !Task.isCancelled, self.live, !self.glassesStreaming else { return }
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
                try await mixer.attachVideo(cam)
                await mixer.setVideoOrientation(.portrait)
                source = "phone"
            }
        } catch {
            rtmpState = "camera switch: \(error.localizedDescription)"
        }
    }

    // MARK: audio inputs

    func refreshMics() {
        let s = AVAudioSession.sharedInstance()
        // allowBluetoothHFP is what makes the glasses show up as an input.
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? s.setActive(true)
        mics = (s.availableInputs ?? []).map { Mic(id: $0.uid, name: $0.portName) }
    }

    func setMuted(_ on: Bool) {
        muted = on
        Task {   // ponytail: mute = detach the mic; AudioMixerSettings per-track flags avoided
            try? await mixer.attachAudio(on ? nil : AVCaptureDevice.default(for: .audio))
        }
    }

    // MARK: RTMP

    func goLive(url: String, key: String, micUID: String, fallbackPosition: AVCaptureDevice.Position) {
        self.fallbackPosition = fallbackPosition
        Task {
            do {
                // Meta docs: audio route must be settled before frames flow; do this before connect.
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                if let port = audioSession.availableInputs?.first(where: { $0.uid == micUID }) {
                    try audioSession.setPreferredInput(port)
                }
                try audioSession.setActive(true)

                if !muted { try await mixer.attachAudio(AVCaptureDevice.default(for: .audio)) }
                await mixer.addOutput(stream)
                await mixer.startRunning()

                // profileLevel containing "HEVC" flips HaishinKit's internal format to .hevc (onMetaData codec id)
                // and makes the fallback-camera encoder produce HEVC too.
                try? await stream.setVideoSettings(VideoCodecSettings(
                    videoSize: CGSize(width: 720, height: 1280),
                    bitRate: 4_000_000,
                    profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    expectedFrameRate: 30))
                try? await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000))

                _ = try await connection.connect(url)
                _ = try await stream.publish(key)
                live = true
                liveSince = Date()
                rtmpState = "live"
                evaluateSource()

                Task { [weak self] in
                    guard let self else { return }
                    while self.live {
                        try? await Task.sleep(for: .seconds(3))
                        // ponytail: fixed 3 s retry, no backoff
                        if !(await self.connection.connected) {
                            self.rtmpState = "reconnecting"
                            _ = try? await self.connection.connect(url)
                            _ = try? await self.stream.publish(key)
                            if await self.connection.connected { self.rtmpState = "live" }
                        }
                    }
                }
            } catch {
                rtmpState = error.localizedDescription
            }
        }
    }

    func stopLive() {
        live = false
        liveSince = nil
        fallbackTask?.cancel()
        rtmpState = "stopped"
        Task {
            try? await mixer.attachVideo(nil)
            try? await connection.close()
        }
        source = "glasses"
        try? AVAudioSession.sharedInstance().setActive(false)
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
