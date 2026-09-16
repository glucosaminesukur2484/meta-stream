import SwiftUI
import MWDATCore
import AVFoundation
import WebKit

// MARK: - UIKit bridges

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct PreviewView: UIViewRepresentable {
    @EnvironmentObject var streamer: Streamer
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.displayLayer.videoGravity = .resizeAspect
        streamer.preview = view.displayLayer
        if streamer.pip == nil { streamer.pip = PiPController(layer: view.displayLayer) }
        return view
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct ChatView: UIViewRepresentable {
    let url: String
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        load(webView)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { load(uiView) }
    private func load(_ webView: WKWebView) {
        guard let u = URL(string: url), webView.url?.absoluteString != url else { return }
        webView.load(URLRequest(url: u))
    }
}

// MARK: - Live screen

struct ContentView: View {
    @EnvironmentObject var streamer: Streamer
    @EnvironmentObject var speaker: Speaker
    @EnvironmentObject var chat: ChatFeed
    @EnvironmentObject var platforms: Platforms
    @EnvironmentObject var privacy: Privacy
    @AppStorage("rtmpURL") var ingestURL = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    // ponytail: stream key in UserDefaults; move to Keychain if the phone is shared.
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("chatSite") var chatSite = "kick"
    // Which origins get read aloud. The chat SHEET still shows one site (chatSite); the voice feed
    // aggregates, because you can't pick a tab while walking with the phone in your pocket.
    @AppStorage("voiceKick") var voiceKick = true
    @AppStorage("voiceTwitch") var voiceTwitch = true
    @AppStorage("voiceYouTube") var voiceYouTube = true
    @AppStorage("blurOn") var blurOn = false
    @AppStorage("blurFaces") var blurFaces = true
    @AppStorage("blurText") var blurText = true
    @AppStorage("blurBarcodes") var blurBarcodes = true
    @AppStorage("chatChannel") var chatChannel = ""
    @AppStorage("resolution") var resolution = "high"
    @AppStorage("fps") var fpsSetting = 30
    @AppStorage("micUID") var micUID = ""
    @AppStorage("fallbackCamera") var fallbackCamera = "back"
    @AppStorage("keepAwake") var keepAwake = true
    @AppStorage("bitrateKbps") var bitrateKbps = 4000
    @AppStorage("srtLatencyMs") var srtLatencyMs = 2000
    @AppStorage("phoneHeight") var phoneHeight = 720
    @AppStorage("phoneLandscape") var phoneLandscape = false
    @AppStorage("phoneFps") var phoneFps = 30
    @AppStorage("codec") var codecPref = "auto"
    @AppStorage("platform") var platformPref = "kick"
    /// auto: only YouTube (enhanced RTMP) and custom servers take the glasses' HEVC untouched. Kick, Restream,
    /// Instagram and TikTok are H.264-only ingests, and Twitch gates HEVC behind Affiliate, so they get a transcode.
    private var codec: String {
        // adr/0001: blur has to decode every frame to obscure it, so it forces a transcode and
        // outranks even an explicit HEVC choice — you cannot blur a frame you never decode.
        // Precedence: blur > explicit codec > protocol capability > destination table.
        if blurOn { return "h264" }
        guard codecPref == "auto" else { return codecPref }
        // SRT carries whatever the server decodes, and passthrough is the entire reason to use it:
        // no transcode means no PiP window needed to keep streaming in the background.
        if ingestURL.lowercased().hasPrefix("srt://") { return "hevc" }
        return ["youtube", "custom"].contains(platformPref) ? "hevc" : "h264"
    }

    @State private var showSettings = false
    @State private var showChat = false
    @State private var showStatus = false
    @State private var showManager = false
    @State private var photoFlash = false

    @AppStorage("restreamChatURL") var restreamChatURL = ""
    @AppStorage("youtubeVideoID") var youtubeVideoID = ""

    private var chatURL: String {
        switch chatSite {
        case "twitch": return "https://www.twitch.tv/popout/\(chatChannel)/chat"
        case "youtube": return "https://www.youtube.com/live_chat?is_popout=1&v=\(youtubeVideoID)"
        case "restream": return restreamChatURL
        default: return "https://kick.com/popout/\(chatChannel)/chat"
        }
    }
    private var chatConfigured: Bool {
        switch chatSite {
        case "youtube": return !youtubeVideoID.isEmpty
        case "restream": return !restreamChatURL.isEmpty
        default: return !chatChannel.isEmpty
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView().ignoresSafeArea()      // one layer for glasses, phone camera and black frames; PiP uses it too

            if streamer.cameraOff {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill").font(.system(size: 44))
                    Text("Camera off").font(.headline)
                    Text("viewers see black").font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }

            VStack {
                hud
                Spacer()
                quickControls
                controls
            }
            .padding(.horizontal)

            if streamer.registration != "registered" { registerCard }

            if photoFlash {
                Color.white.ignoresSafeArea().transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showManager) { StreamManagerView() }
        .sheet(isPresented: $showChat) {
            chatSheet
                .presentationDetents([.fraction(0.45), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
                .presentationDragIndicator(.visible)
                .presentationBackground(.black)
        }
        .alert("Status", isPresented: $showStatus) { Button("OK") {} } message: {
            Text("Meta: \(streamer.registration)\nGlasses: \(streamer.glassesState)\nDevices: \(streamer.devices)\nRTMP: \(streamer.rtmpState)\nDrops: \(streamer.drops)\nFrames: \(streamer.frames)\nTeam ID: \(streamer.teamID)" + (streamer.sessionSummary.map { "\nLast: \($0)" } ?? ""))
        }
        .task {
            // ponytail: one consumer for the app's lifetime. ChatFeed buffers, Speaker bounds its own lanes,
            // so nothing here needs backpressure handling.
            for await e in chat.events { speaker.speak(e) }
        }
        .onAppear { startChat(); applyBlur() }
        .onChange(of: blurOn) { _, _ in applyBlur() }
        .onChange(of: blurFaces) { _, _ in applyBlur() }
        .onChange(of: blurText) { _, _ in applyBlur() }
        .onChange(of: blurBarcodes) { _, _ in applyBlur() }
        .onChange(of: chatChannel) { _, _ in startChat() }
        .onChange(of: voiceKick) { _, _ in startChat() }
        .onChange(of: voiceTwitch) { _, _ in startChat() }
        .onChange(of: voiceYouTube) { _, _ in startChat() }
        .onChange(of: platforms.twitchConnected) { _, _ in startChat() }
        .onChange(of: platforms.ytConnected) { _, _ in startChat() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onChange(of: keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
        .onChange(of: streamer.lastPhotoAt) { _, _ in
            withAnimation(.easeOut(duration: 0.1)) { photoFlash = true }
            Task { try? await Task.sleep(for: .milliseconds(120)); withAnimation(.easeIn(duration: 0.3)) { photoFlash = false } }
        }
    }

    // MARK: HUD

    private var hud: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showStatus = true } label: {
                    pill("eyeglasses", streamer.glassesShort, glassesColor)
                }
                .buttonStyle(.plain)

                if streamer.live {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        // Amber while down: the timer measures the session, never the connection, so it
                        // has to show degraded time rather than quietly counting dead air as healthy.
                        let down = streamer.connectedSince == nil
                        pill(down ? "exclamationmark.triangle.fill" : "record.circle.fill",
                             down ? "down " + elapsed(ctx.date) : elapsed(ctx.date),
                             down ? .orange : .red)
                    }
                    pill("waveform", "\(streamer.fps) fps · \(streamer.kbps) kbps", .white)
                    if streamer.currentBitrateKbps > 0, streamer.currentBitrateKbps < bitrateKbps {
                        pill("arrow.down.right.circle", "\(streamer.currentBitrateKbps)k cap", .orange)
                    }
                } else {
                    pill("antenna.radiowaves.left.and.right", streamer.rtmpState, .gray)
                }
                if let pb = streamer.phoneBattery, pb < 30 {
                    pill("battery.25", "phone \(pb)%", pb < 15 ? .orange : .white)
                }
                if let gt = streamer.glassesThermal, let heat = glassesHeat(gt) {
                    pill("thermometer", "glasses \(heat)", heat == "warm" ? .white : .orange)
                }
                if blurOn {
                    pill(privacy.stalled ? "eye.trianglebadge.exclamationmark" : "eye.slash.fill",
                         privacy.stalled ? "blur failed" : "blur", privacy.stalled ? .orange : .white)
                }
                if streamer.thermal != .nominal {
                    pill("thermometer", thermalLabel, streamer.thermal == .fair ? .white : .orange)
                }
                pill(streamer.source == "phone" ? "iphone" : "eyeglasses",
                     streamer.manualSource == "auto" ? "auto · \(streamer.source)" : streamer.manualSource,
                     streamer.source == "phone" ? .orange : .white)
                Button { tap(); speaker.muted.toggle() } label: {
                    // Silences chat and alerts only. Stream warnings speak regardless — see Speaker.
                    pill(speaker.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", speaker.muted ? "tts off" : "tts", speaker.muted ? .orange : .white)
                }
                .buttonStyle(.plain)
                Button { tap(); streamer.capturePhoto() } label: {
                    pill("camera.shutter.button", "photo", .white)
                }
                .buttonStyle(.plain)
                .disabled(streamer.glassesShort != "streaming")
                .opacity(streamer.glassesShort == "streaming" ? 1 : 0.4)
                Button { tap(); showManager = true } label: {
                    pill("slider.horizontal.3", "manage", .cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    /// Privacy exposes plain vars, not @Published — a published hot path would cost a MainActor hop on
    /// every decoded frame. So settings are written through here instead of bound.
    private func applyBlur() {
        privacy.enabled = blurOn
        privacy.options = .init(faces: blurFaces, text: blurText, barcodes: blurBarcodes)
    }

    /// Starts every enabled origin that has what it needs. Kick needs only a slug; Twitch and YouTube
    /// need a connected account. Each origin is owned by exactly one feed, so nothing arrives twice.
    private func startChat() {
        var origins = 0
        if voiceKick, !chatChannel.isEmpty { chat.start(kickSlug: chatChannel); origins += 1 } else { chat.stopKick() }
        if voiceTwitch, platforms.twitchConnected { chat.startTwitch(platforms: platforms); origins += 1 } else { chat.stopTwitch() }
        if voiceYouTube, platforms.ytConnected { chat.startYouTube(platforms: platforms); origins += 1 } else { chat.stopYouTube() }
        // Only prefix "on Kick, …" when more than one origin is live — otherwise it's noise on every line.
        speaker.showOrigin = origins > 1
    }

    /// Shows what is actually on air, not what was asked for — on auto those differ whenever the
    /// glasses drop and the phone takes over.
    private var sourceIcon: String {
        switch streamer.manualSource {
        case "glasses": return "eyeglasses"
        case "back": return "camera.fill"
        case "front": return "camera.rotate.fill"
        default: return streamer.source == "phone" ? "iphone" : "eyeglasses"
        }
    }

    /// nil below moderate — a pill that never clears is noise on a screen you glance at mid-walk.
    private func glassesHeat(_ level: ThermalLevel) -> String? {
        switch level {
        case .moderate: return "warm"
        case .severe: return "hot"
        case .critical, .emergency, .shutdown: return "overheating"
        default: return nil
        }
    }

    private var thermalLabel: String {
        switch streamer.thermal {
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "overheating"
        default: return "ok"
        }
    }

    private var glassesColor: Color {
        switch streamer.glassesShort {
        case "streaming": return .green
        case "connecting": return .orange
        default: return .gray
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard let since = streamer.liveSince else { return "00:00" }
        let s = Int(now.timeIntervalSince(since))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func pill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .center, spacing: 18) {
            roundButton(streamer.glassesOn ? "eyeglasses" : "eyeglasses.slash", filled: streamer.glassesOn) {
                tap()
                streamer.glassesOn ? streamer.stopGlasses() : streamer.startGlasses(resolution: resolution, fps: UInt(fpsSetting))
            }
            // A picker, not a cycler: hunting for the right source by tapping through four states is
            // the wrong interaction when the shot is already wrong on stream.
            Menu {
                Picker("Video source", selection: Binding(get: { streamer.manualSource },
                                                          set: { tap(); streamer.setSource($0) })) {
                    Label("Auto", systemImage: "wand.and.stars").tag("auto")
                    Label("Glasses", systemImage: "eyeglasses").tag("glasses")
                    Label("Back camera", systemImage: "camera.fill").tag("back")
                    Label("Front camera", systemImage: "camera.rotate.fill").tag("front")
                }
            } label: {
                Image(systemName: sourceIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(streamer.manualSource == "auto" ? .white : .black)
                    .frame(width: 52, height: 52)
                    .background(streamer.manualSource == "auto" ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.white), in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                tap(strong: true)
                if streamer.live {
                    streamer.stopLive()
                } else {
                    streamer.goLive(url: ingestURL, key: streamKey, micUID: micUID,
                                    fallbackPosition: fallbackCamera == "front" ? .front : .back,
                                    bitrateKbps: bitrateKbps, codec: codec, srtLatencyMs: srtLatencyMs,
                                    quality: .init(height: phoneHeight, landscape: phoneLandscape, fps: phoneFps))
                }
            } label: {
                ZStack {
                    Circle().fill(streamer.live ? Color.red : Color.green)
                        .frame(width: 84, height: 84)
                        .shadow(color: (streamer.live ? Color.red : Color.green).opacity(0.5), radius: 12)
                    Text(streamer.live ? "END" : "GO\nLIVE")
                        .font(.system(size: 15, weight: .heavy)).multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .animation(.spring(duration: 0.3), value: streamer.live)

            roundButton("bubble.left.and.bubble.right.fill", filled: showChat) { tap(); showChat.toggle() }
            roundButton("gearshape.fill", filled: false) { tap(); showSettings = true }
        }
        .padding(.bottom, 12)
    }

    /// Mic, camera and privacy, fixed and always on screen. These are the controls you need in the second
    /// something goes wrong, so they must never live in the scrolling status strip where a long run of
    /// pills can push them off the edge — you cannot scroll a pill row one-handed while walking.
    private var quickControls: some View {
        HStack(spacing: 12) {
            quickButton(streamer.muted ? "mic.slash.fill" : "mic.fill",
                        streamer.muted ? "Muted" : "Mic",
                        style: streamer.muted ? .stopped : .live) {
                streamer.setMuted(!streamer.muted)
            }

            quickButton(streamer.cameraOff ? "video.slash.fill" : "video.fill",
                        streamer.cameraOff ? "Hidden" : "Camera",
                        style: streamer.cameraOff ? .stopped : .live) {
                streamer.setCameraOff(!streamer.cameraOff)
            }

            quickButton(blurOn ? "eye.slash.fill" : "eye.fill",
                        blurOn ? (streamer.live && !streamer.transcoding ? "Next stream" : "Blur on") : "Blur off",
                        style: !blurOn ? .off : (streamer.live && !streamer.transcoding ? .pending : .protecting)) {
                blurOn.toggle()
            }
        }
        .padding(.bottom, 10)
    }

    /// One colour per meaning, never two shades of the same thing: green is going out, red is not going
    /// out, blue is actively protecting, amber is asked for but not in effect, grey is off. A toggle you
    /// have to squint at is useless at the moment you need it.
    private enum QuickStyle {
        case live, stopped, protecting, pending, off
        var tint: Color? {
            switch self {
            case .live: return .green
            case .stopped: return .red
            case .protecting: return .blue
            case .pending: return .orange
            case .off: return nil
            }
        }
    }

    private func quickButton(_ icon: String, _ label: String, style: QuickStyle,
                             action: @escaping () -> Void) -> some View {
        Button {
            tap(strong: true)
            action()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                Text(label).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(style.tint.map { AnyShapeStyle($0.gradient) } ?? AnyShapeStyle(.ultraThinMaterial))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(style.tint == nil ? 0.25 : 0), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func roundButton(_ icon: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: 52, height: 52)
                .background(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func tap(strong: Bool = false) {
        UIImpactFeedbackGenerator(style: strong ? .heavy : .light).impactOccurred()
    }

    // MARK: First run

    private var registerCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "eyeglasses").font(.system(size: 40))
            Text("Connect your glasses").font(.title3.bold())
            Text("In the Meta AI app: Settings → App Info → tap the version 5× → turn on Developer Mode. Then register this app.")
                .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button {
                tap(); streamer.register()
            } label: {
                Label("Register with Meta AI", systemImage: "link").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text(streamer.registration).font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    // MARK: Chat sheet

    private var chatSheet: some View {
        Group {
            if !chatConfigured {
                VStack(spacing: 12) {
                    Text("No chat source set").font(.headline)
                    Text("Set a channel name in Settings, or connect a platform in Stream Manager and tap “Use for streaming”.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("Settings") { showChat = false; showSettings = true }
                        Button("Stream Manager") { showChat = false; showManager = true }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatView(url: chatURL).ignoresSafeArea(edges: .bottom)
            }
        }
        .padding(.top, 8)
    }
}
