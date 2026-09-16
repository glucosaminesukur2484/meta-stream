import SwiftUI
import AVFoundation
import Foundation

/// Top-level settings: a category list, each pushing its own Form (standard iOS pattern). Every
/// @AppStorage key below is unchanged from the old single-Form layout -- moving a setting to a new
/// screen never touches its key, so nobody's saved value gets silently discarded by this reorg.
/// ponytail: no search. A search index needs hand-maintaining as settings are added and rots silently
/// the moment someone forgets to update it -- seven categories is small enough to scan by eye.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Ingest & protocol") { IngestSettingsView() }
                    NavigationLink("Video (glasses)") { GlassesVideoSettingsView() }
                    NavigationLink("Camera") { CameraSettingsView() }
                    NavigationLink("Audio") { AudioSettingsView() }
                    NavigationLink("Read aloud") { ReadAloudSettingsView() }
                    NavigationLink("Privacy") { PrivacySettingsView() }
                }
                Section {
                    NavigationLink("Diagnostics & about") { DiagnosticsSettingsView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Ingest & protocol

struct IngestSettingsView: View {
    @AppStorage("platform") var platform = "kick"
    @AppStorage("rtmpURL") var ingestURL = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("codec") var codec = "auto"
    @AppStorage("bitrateKbps") var bitrateKbps = 4000
    @AppStorage("srtLatencyMs") var srtLatencyMs = 2000
    @AppStorage("chatSite") var chatSite = "kick"
    @AppStorage("chatChannel") var chatChannel = ""
    @State private var showKey = false

    // Ingest URLs. Instagram and TikTok hand out a per-stream URL in their own tools, so they stay "custom".
    private static let presets: [String: String] = [
        "kick": "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/",
        "twitch": "rtmps://live.twitch.tv:443/app/",
        "youtube": "rtmps://a.rtmps.youtube.com:443/live2",
        "restream": "rtmp://live.restream.io/live",
    ]
    private static let hints: [String: String] = [
        "kick": "H.264 only, up to 8000 kbps. Transcoding uses the phone's decoder, which iOS stops in the background unless the Picture in Picture window stays open.",
        "twitch": "Up to 6000 kbps, 8000 for Partners. HEVC is Affiliate/Partner only, so Auto sends H.264.",
        "youtube": "Takes the glasses' HEVC untouched over enhanced RTMP, so it also keeps streaming in the background. Create the stream in YouTube Studio first.",
        "restream": "Fans out to every destination set up in the Restream dashboard. Their RTMP ingest is H.264 only (HEVC needs SRT), so Auto transcodes.",
        "instagram": "Open Live Producer on instagram.com (desktop) and copy the stream URL and key here. H.264 only, up to 4000 kbps.",
        "tiktok": "Get the server URL and key from TikTok LIVE Studio and paste both here. H.264 only.",
        "custom": "Any RTMP, RTMPS or SRT server, such as your own relay. Paste an srt:// URL to publish over SRT, which survives packet loss far better on cellular — put the stream key in its streamid query item, since SRT has no separate publish name. Auto sends HEVC untouched; switch to H.264 if your server refuses it.",
    ]

    var body: some View {
        Form {
            Section {
                Picker("Platform", selection: $platform) {
                    Text("Kick").tag("kick"); Text("Twitch").tag("twitch"); Text("YouTube").tag("youtube")
                    Text("Restream").tag("restream"); Text("Instagram").tag("instagram"); Text("TikTok").tag("tiktok")
                    Text("Custom").tag("custom")
                }
                .onChange(of: platform) { _, p in
                    if let url = Self.presets[p] { ingestURL = url } else if p != "custom" { ingestURL = "" }
                }
                TextField("Ingest URL", text: $ingestURL)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                HStack {
                    if showKey {
                        TextField("Stream key", text: $streamKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        SecureField("Stream key", text: $streamKey)
                    }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Picker("Video codec", selection: $codec) {
                    Text("Auto").tag("auto"); Text("HEVC (passthrough)").tag("hevc"); Text("H.264 (transcode)").tag("h264")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Bitrate"); Spacer(); Text(String(bitrateKbps) + " kbps").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { Double(bitrateKbps) }, set: { bitrateKbps = Int($0 / 250) * 250 }),
                           in: 1000...9000, step: 250)
                }
                if ingestURL.lowercased().hasPrefix("srt://") {
                    Stepper("SRT buffer \(srtLatencyMs) ms", value: $srtLatencyMs, in: 200...8000, step: 200)
                }
            } header: { Text("Ingest") } footer: {
                Text((Self.hints[platform] ?? "") + "\nAuto picks H.264 for Kick and Twitch (they don't take HEVC) and passthrough elsewhere. H.264 re-encodes on the phone at the bitrate below; HEVC passthrough keeps the glasses' own bitrate.")
            }

            Section("Chat") {
                Picker("Chat platform", selection: $chatSite) { Text("Kick").tag("kick"); Text("Twitch").tag("twitch") }
                TextField("Channel name", text: $chatChannel).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
        .navigationTitle("Ingest & protocol")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Video (glasses)

struct GlassesVideoSettingsView: View {
    @AppStorage("resolution") var resolution = "high"
    @AppStorage("fps") var fps = 30

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $resolution) {
                    Text("Low · 360×640").tag("low"); Text("Medium · 504×896").tag("medium"); Text("High · 720×1280").tag("high")
                }
                Picker("Frame rate", selection: $fps) { Text("15").tag(15); Text("24").tag(24); Text("30").tag(30) }
            } footer: {
                Text("Applied the next time the glasses session starts. 720×1280 at 30 fps is the ceiling — Meta's SDK offers third-party apps nothing higher, so no setting here can raise it.")
            }
        }
        .navigationTitle("Video (glasses)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Camera (phone)

struct CameraSettingsView: View {
    @AppStorage("fallbackCamera") var fallbackCamera = "back"
    @AppStorage("phoneHeight") var phoneHeight = 720
    @AppStorage("phoneLandscape") var phoneLandscape = false
    @AppStorage("phoneFps") var phoneFps = 30
    @AppStorage("phoneStabilization") var phoneStabilization = "off"

    @AppStorage("camLens") var camLens = "wide"
    @AppStorage("camZoom") var camZoom = 1.0
    @AppStorage("camFocusMode") var camFocusMode = "continuous"
    @AppStorage("camLensPosition") var camLensPosition = 0.5
    @AppStorage("camSmoothAutoFocus") var camSmoothAutoFocus = true
    @AppStorage("camFaceDrivenAutoFocus") var camFaceDrivenAutoFocus = true
    @AppStorage("camExposureManual") var camExposureManual = false
    @AppStorage("camExposureBiasEV") var camExposureBiasEV = 0.0
    @AppStorage("camManualISO") var camManualISO = 200.0
    @AppStorage("camManualShutterMs") var camManualShutterMs = 33.3
    @AppStorage("camLowLightBoost") var camLowLightBoost = true
    @AppStorage("camWhiteBalanceManual") var camWhiteBalanceManual = false
    @AppStorage("camWBTemperature") var camWBTemperature = 5500.0
    @AppStorage("camWBTint") var camWBTint = 0.0
    @AppStorage("camHDR") var camHDR = "auto"
    @AppStorage("camTorchLevel") var camTorchLevel = 0.0
    @AppStorage("camMirrored") var camMirrored = false
    @AppStorage("camGDC") var camGDC = true

    // Re-probed whenever lens or position changes -- front/back and wide/ultrawide/telephoto genuinely
    // differ in what they support, so a stale probe would grey out (or wrongly enable) the wrong controls.
    @State private var cap: CameraCapabilities?

    private var position: AVCaptureDevice.Position { fallbackCamera == "front" ? .front : .back }

    var body: some View {
        Form {
            if cap == nil {
                Section {
                    Text("No camera found for this lens/position on this device (expected in Simulator). Settings below still save, but can't be checked against real hardware here.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Camera", selection: $fallbackCamera) { Text("Back").tag("back"); Text("Front").tag("front") }
                    .pickerStyle(.segmented)
                Picker("Lens", selection: $camLens) {
                    ForEach(CameraLens.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            } header: { Text("Lens") } footer: {
                Text("Also the fallback camera used automatically while the glasses are disconnected. A lens this iPhone doesn't have (e.g. telephoto on a non-Pro model) falls back to the wide lens.")
            }

            Section("Zoom") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Zoom"); Spacer(); Text(String(format: "%.2fx", camZoom)).monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $camZoom, in: cap?.zoomRange ?? 1...1)
                }
            }
            .disabled(cap == nil)

            Section {
                Picker("Mode", selection: $camFocusMode) {
                    Text("Continuous").tag("continuous").disabled(!(cap?.focusContinuous ?? false))
                    Text("Auto (single-shot)").tag("auto").disabled(!(cap?.focusAuto ?? false))
                    Text("Manual").tag("manual").disabled(!(cap?.focusManual ?? false))
                }
                if camFocusMode == "manual" {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Lens position"); Spacer(); Text(String(format: "%.2f", camLensPosition)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $camLensPosition, in: 0...1)
                    }
                }
                Toggle("Smooth autofocus", isOn: $camSmoothAutoFocus).disabled(!(cap?.smoothAutoFocus ?? false))
                Toggle("Face-driven autofocus", isOn: $camFaceDrivenAutoFocus)
            } header: { Text("Focus") } footer: {
                Text("Smooth autofocus trades focus speed for less visible hunting — designed for video, worth leaving on for anything handheld or walking. 0 is closest, 1 is furthest for manual lens position.")
            }

            Section {
                Toggle("Manual exposure", isOn: $camExposureManual).disabled(!(cap?.exposureManual ?? false))
                if camExposureManual {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("ISO"); Spacer(); Text("\(Int(camManualISO))").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $camManualISO, in: cap?.isoRange ?? 100...100)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Shutter"); Spacer(); Text("1/\(max(1, Int(1000 / max(camManualShutterMs, 0.1))))s").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $camManualShutterMs, in: cap?.shutterRangeMs ?? 1...1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Exposure bias"); Spacer(); Text(String(format: "%.1f EV", camExposureBiasEV)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $camExposureBiasEV, in: cap?.exposureBiasRange ?? 0...0)
                    }
                }
                Toggle("Low-light boost", isOn: $camLowLightBoost).disabled(!(cap?.lowLightBoost ?? false))
            } header: { Text("Exposure") } footer: {
                Text("Manual exposure fixes ISO and shutter speed instead of letting the camera track the scene — set this walking into a place you know is dark or bright, not mid-stream. Off, the exposure bias slider still nudges auto exposure brighter or darker.")
            }

            Section {
                Toggle("Manual white balance", isOn: $camWhiteBalanceManual).disabled(!(cap?.whiteBalanceManual ?? false))
                if camWhiteBalanceManual {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Temperature"); Spacer(); Text("\(Int(camWBTemperature))K").monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $camWBTemperature, in: 2500...10000)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Tint"); Spacer(); Text(String(format: "%.0f", camWBTint)).monospacedDigit().foregroundStyle(.secondary) }
                        Slider(value: $camWBTint, in: -150...150)
                    }
                }
            } header: { Text("White balance") } footer: {
                Text("Locks color instead of letting it drift as lighting changes across a walk — mainly useful going indoor↔outdoor repeatedly and wanting one consistent look.")
            }

            Section {
                Picker("HDR", selection: $camHDR) {
                    Text("Auto").tag("auto")
                    Text("On").tag("on").disabled(!(cap?.hdr ?? false))
                    Text("Off").tag("off").disabled(!(cap?.hdr ?? false))
                }
                Toggle("Mirror", isOn: $camMirrored)
                Toggle("Geometric distortion correction", isOn: $camGDC).disabled(!(cap?.geometricDistortionCorrection ?? false))
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Torch"); Spacer(); Text(camTorchLevel <= 0 ? "Off" : String(format: "%.0f%%", camTorchLevel * 100)).monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: $camTorchLevel, in: 0...1)
                }
                .disabled(!(cap?.torch ?? false))
            } header: { Text("Image") } footer: {
                Text("Geometric distortion correction straightens the ultra-wide lens's fisheye look; matters most on that lens. Torch is a fill light for the whole session, not a camera flash — it drains battery fast at high levels.")
            }

            Section {
                Picker("Resolution", selection: $phoneHeight) { Text("720p").tag(720); Text("1080p").tag(1080) }
                Picker("Aspect", selection: $phoneLandscape) { Text("Portrait 9:16").tag(false); Text("Landscape 16:9").tag(true) }
                Picker("Frame rate", selection: $phoneFps) { Text("24").tag(24); Text("30").tag(30); Text("60").tag(60) }
                Picker("Stabilisation", selection: $phoneStabilization) {
                    Text("Off").tag("off"); Text("Standard").tag("standard"); Text("Cinematic").tag("cinematic"); Text("Action").tag("action")
                }
            } header: { Text("Resolution & stabilisation") } footer: {
                Text("Stabilisation crops the picture and the stronger modes add capture latency, so Standard is the safe pick for a live stream and Action is for rough movement you would otherwise not be able to watch. Fixed for the whole stream — set it before going live. A mode the current resolution can't do is ignored by iOS rather than refused.")
            }
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onChange(of: camLens) { _, _ in refresh() }
        .onChange(of: fallbackCamera) { _, _ in refresh() }
    }

    private func refresh() { cap = CameraCapabilities.probe(lens: camLens, position: position) }
}

// MARK: - Audio

struct AudioSettingsView: View {
    @EnvironmentObject var streamer: Streamer
    @AppStorage("micUID") var micUID = ""

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $micUID) {
                    Text("Default").tag("")
                    ForEach(streamer.mics) { Text($0.name).tag($0.id) }
                }
                Toggle("Mute microphone", isOn: Binding(get: { streamer.muted }, set: { streamer.setMuted($0) }))
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { streamer.refreshMics() }
    }
}

// MARK: - Read aloud

struct ReadAloudSettingsView: View {
    @EnvironmentObject var platforms: Platforms
    @AppStorage("ttsMessagesOn") var ttsMessagesOn = true
    @AppStorage("ttsTipsOn") var ttsTipsOn = true
    @AppStorage("ttsFollowsOn") var ttsFollowsOn = true
    @AppStorage("ttsSubsOn") var ttsSubsOn = true
    @AppStorage("ttsRaidsOn") var ttsRaidsOn = true
    @AppStorage("ttsRate") var ttsRate = 0.5
    @AppStorage("ttsMinTipCents") var ttsMinTipCents = 0
    @AppStorage("voiceKick") var voiceKick = true
    @AppStorage("voiceTwitch") var voiceTwitch = true
    @AppStorage("voiceYouTube") var voiceYouTube = true

    var body: some View {
        Form {
            Section {
                Toggle("Chat messages", isOn: $ttsMessagesOn)
                Toggle("Tips and bits", isOn: $ttsTipsOn)
                Toggle("Follows", isOn: $ttsFollowsOn)
                Toggle("Subscriptions", isOn: $ttsSubsOn)
                Toggle("Raids", isOn: $ttsRaidsOn)
                VStack(alignment: .leading) {
                    Text("Speed").font(.footnote).foregroundStyle(.secondary)
                    Slider(value: $ttsRate, in: 0.35...0.65)
                }
                Stepper("Read tips from $\(ttsMinTipCents / 100)", value: $ttsMinTipCents, in: 0...5000, step: 100)
                Toggle("Kick chat", isOn: $voiceKick)
                Toggle("Twitch chat", isOn: $voiceTwitch)
                Toggle("YouTube chat", isOn: $voiceYouTube)
                if !platforms.twitchMissingScopeFeatures.isEmpty, platforms.twitchConnected {
                    Text("Reconnect Twitch in Manage to enable \(platforms.twitchMissingScopeFeatures.joined(separator: ", ")).")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                Text("Chat is spoken through whatever is playing audio, so the glasses' open-ear speakers when they are connected. The tts pill on the live screen silences chat and alerts; stream warnings such as a dropped connection always speak.\n\nWith the glasses microphone selected, the open-ear speakers can bleed back into your audio. Use the phone microphone if viewers hear an echo.")
            }
        }
        .navigationTitle("Read aloud")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @AppStorage("blurOn") var blurOn = false
    @AppStorage("blurFaces") var blurFaces = true
    @AppStorage("blurText") var blurText = true
    @AppStorage("blurBarcodes") var blurBarcodes = true

    var body: some View {
        Form {
            Section {
                Toggle("Privacy blur", isOn: $blurOn)
                if blurOn {
                    Toggle("Faces", isOn: $blurFaces)
                    Toggle("Text and licence plates", isOn: $blurText)
                    Toggle("QR codes and barcodes", isOn: $blurBarcodes)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pixellates faces, text and codes in the outgoing video. Licence plates come from the text detector, since a plate is text.")
                    Text("This is best effort, not a guarantee. Detection runs per frame and misses profile faces, motion blur, distance and low light, so some frames go out unobscured and there is no undo on a live stream. It reduces what gets seen; it is not a substitute for not pointing the camera at something.")
                    Text("Turning it on forces a transcode on every destination, because a frame has to be decoded to be altered. That costs battery and heat, and background streaming will need the Picture in Picture window. If detection stops working the camera is hidden and you are told, rather than the stream quietly going clear.")
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Diagnostics & about

struct DiagnosticsSettingsView: View {
    @EnvironmentObject var streamer: Streamer
    @AppStorage("keepAwake") var keepAwake = true

    var body: some View {
        Form {
            Section("General") {
                Toggle("Keep screen awake", isOn: $keepAwake)
            }
            Section("Logs") {
                NavigationLink("View logs") { LogView() }
            }
            Section("About") {
                row("Apple Team ID", streamer.teamID)
                row("Meta registration", streamer.registration)
                row("Devices", streamer.devices)
                row("Version", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")")
            }
        }
        .navigationTitle("Diagnostics & about")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
    }
}
