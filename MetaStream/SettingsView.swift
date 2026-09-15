import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var streamer: Streamer
    @Environment(\.dismiss) private var dismiss

    @AppStorage("platform") var platform = "kick"
    @AppStorage("rtmpURL") var rtmpURL = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
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
    @State private var showKey = false

    // Ingest URLs. Instagram and TikTok hand out a per-stream URL in their own tools, so they stay "custom".
    private static let presets: [String: String] = [
        "kick": "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/",
        "twitch": "rtmps://live.twitch.tv:443/app/",
        "youtube": "rtmps://a.rtmps.youtube.com:443/live2",
        "restream": "rtmp://live.restream.io/live",
    ]
    private static let hints: [String: String] = [
        "kick": "Kick accepts up to 8000 kbps, H.264 only.",
        "twitch": "Twitch: up to 6000 kbps (8000 for Partners). HEVC only for Affiliates/Partners.",
        "youtube": "YouTube: up to ~9000 kbps at 1080p. Create the stream in YouTube Studio first.",
        "restream": "Restream re-encodes to H.264 for every destination, so Twitch works even without Affiliate.",
        "instagram": "Instagram: open Live Producer on instagram.com (desktop), copy the stream URL + key here. ≤ 4000 kbps.",
        "tiktok": "TikTok: get the server URL + key from TikTok LIVE Studio and paste both here.",
        "custom": "Any RTMP/RTMPS server, e.g. your own relay.",
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
                        if let url = Self.presets[p] { rtmpURL = url } else if p != "custom" { rtmpURL = "" }
                    }
                    TextField("RTMP URL", text: $rtmpURL)
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
                } header: { Text("Destination") } footer: {
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
