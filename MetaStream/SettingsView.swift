import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var streamer: Streamer
    @Environment(\.dismiss) private var dismiss

    @AppStorage("platform") var platform = "kick"
    @AppStorage("rtmpURL") var ingestURL = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("chatSite") var chatSite = "kick"
    @AppStorage("chatChannel") var chatChannel = ""
    @AppStorage("resolution") var resolution = "high"
    @AppStorage("fps") var fps = 30
    @AppStorage("micUID") var micUID = ""
    @AppStorage("fallbackCamera") var fallbackCamera = "back"
    @AppStorage("keepAwake") var keepAwake = true
    @AppStorage("bitrateKbps") var bitrateKbps = 4000
    @AppStorage("codec") var codec = "auto"
    @AppStorage("srtLatencyMs") var srtLatencyMs = 2000
    @AppStorage("ttsMessagesOn") var ttsMessagesOn = true
    @AppStorage("ttsTipsOn") var ttsTipsOn = true
    @AppStorage("ttsFollowsOn") var ttsFollowsOn = true
    @AppStorage("ttsSubsOn") var ttsSubsOn = true
    @AppStorage("ttsRaidsOn") var ttsRaidsOn = true
    @AppStorage("ttsRate") var ttsRate = 0.5
    @AppStorage("ttsMinTipCents") var ttsMinTipCents = 0
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
        NavigationStack {
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

                Section {
                    Picker("Resolution", selection: $resolution) {
                        Text("Low · 360×640").tag("low"); Text("Medium · 504×896").tag("medium"); Text("High · 720×1280").tag("high")
                    }
                    Picker("Frame rate", selection: $fps) { Text("15").tag(15); Text("24").tag(24); Text("30").tag(30) }
                } header: { Text("Video (glasses)") } footer: { Text("Applied the next time the glasses session starts.") }

                Section("Audio") {
                    Picker("Microphone", selection: $micUID) {
                        Text("Default").tag("")
                        ForEach(streamer.mics) { Text($0.name).tag($0.id) }
                    }
                    Toggle("Mute microphone", isOn: Binding(get: { streamer.muted }, set: { streamer.setMuted($0) }))
                }

                Section {
                    Picker("Fallback camera", selection: $fallbackCamera) { Text("Back").tag("back"); Text("Front").tag("front") }
                        .pickerStyle(.segmented)
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
                } header: { Text("Read aloud") } footer: {
                    Text("Chat is spoken through whatever is playing audio, so the glasses' open-ear speakers when they are connected. The tts pill on the live screen silences chat and alerts; stream warnings such as a dropped connection always speak.\n\nWith the glasses microphone selected, the open-ear speakers can bleed back into your audio. Use the phone microphone if viewers hear an echo.")
                }

                } header: { Text("Fallback camera") } footer: {
                    Text("Used automatically while the glasses are disconnected, so the stream never goes black.")
                }

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
            .onAppear { streamer.refreshMics() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospaced()).textSelection(.enabled)
        }
    }
}
