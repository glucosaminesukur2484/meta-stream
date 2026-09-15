import Foundation
import Combine
import AVFoundation
import CoreMedia
import VideoToolbox
import MWDATCore
import MWDATCamera
import HaishinKit
import RTMPHaishinKit

@MainActor
final class Streamer: ObservableObject {
    @Published var registration = "unknown"
    @Published var glassesState = "idle"
    @Published var rtmpState = "idle"
    @Published var frames = 0
    @Published var teamID = "unknown (not sideloaded yet)"
    @Published var live = false

    // ponytail: ContentView sets this directly instead of a delegate protocol.
    weak var preview: AVSampleBufferDisplayLayer?

    private var session: DeviceSession?
    private var camera: Camera?
    private var tokens: [any AnyListenerToken] = []   // SDK listeners die when their token is released

    private let connection = RTMPConnection()          // advertises hvc1 in the enhanced-RTMP connect by default
    private lazy var stream = RTMPStream(connection: connection)
    private let mixer = MediaMixer()

    init() {
        teamID = Self.readTeamID()
        Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                self?.registration = String(describing: state)
            }
        }
    }

    func register() {
        Task {
            do { try await Wearables.shared.startRegistration() } catch { registration = error.localizedDescription }
        }
    }

    func startGlasses() {
        Task {
            do {
                // ponytail: not branching on the returned status; createSession fails anyway if denied.
                _ = try await Wearables.shared.requestPermission(.camera)

                let session = try Wearables.shared.createSession(deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))
                self.session = session

                // hvc1 = compressed HEVC, keeps delivering while the app is in the background. .high = 720x1280.
                let config = StreamConfiguration(videoCodec: .hvc1, resolution: .high, frameRate: 30)
                guard let camera = try session.addCamera(config: config) else {
                    glassesState = "no camera"
                    return
                }
                self.camera = camera

                tokens.append(camera.stream.statePublisher.listen { [weak self] state in
                    Task { @MainActor in self?.glassesState = String(describing: state) }
                })
                tokens.append(camera.stream.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in self?.glassesState = error.localizedDescription }
                })
                tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
                    Task { @MainActor in
                        guard let self else { return }
                        self.frames += 1
                        if self.live {
                            Task { await self.stream.append(frame.sampleBuffer) }   // compressed → passthrough, no encode
                        }
                        if let preview = self.preview {
                            if preview.status == .failed { preview.flush() }
                            preview.enqueue(frame.sampleBuffer)                  // layer decodes HEVC itself
                        }
                    }
                })

                try session.start()
                camera.stream.start()
                glassesState = "starting"
            } catch {
                glassesState = error.localizedDescription
            }
        }
    }

    func stopGlasses() {
        camera?.stream.stop()
        camera?.stop()
        session?.stop()
        tokens.removeAll()
        glassesState = "stopped"
    }

    func goLive(url: String, key: String, glassesMic: Bool) {
        Task {
            do {
                // Meta docs: audio route must be settled before frames flow; do this before connect.
                var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
                if glassesMic { options.insert(.allowBluetoothHFP) }
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playAndRecord, mode: .default, options: options)
                try audioSession.setActive(true)

                try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
                await mixer.addOutput(stream)
                await mixer.startRunning()

                // profileLevel containing "HEVC" flips HaishinKit's internal format to .hevc (onMetaData codec id).
                try? await stream.setVideoSettings(VideoCodecSettings(
                    videoSize: CGSize(width: 720, height: 1280),
                    bitRate: 4_000_000,
                    profileLevel: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                    expectedFrameRate: 30))
                try? await stream.setAudioSettings(AudioCodecSettings(bitRate: 96_000))

                _ = try await connection.connect(url)
                _ = try await stream.publish(key)
                live = true
                rtmpState = "live"

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
        rtmpState = "stopped"
        Task { try? await connection.close() }
        try? AVAudioSession.sharedInstance().setActive(false)
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
