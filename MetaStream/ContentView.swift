import SwiftUI
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
    @AppStorage("rtmpURL") var rtmpURL = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    // ponytail: stream key in UserDefaults; move to Keychain if the phone is shared.
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("chatSite") var chatSite = "kick"
    @AppStorage("chatChannel") var chatChannel = ""
    @AppStorage("resolution") var resolution = "high"
    @AppStorage("fps") var fpsSetting = 30
    @AppStorage("micUID") var micUID = ""
    @AppStorage("fallbackCamera") var fallbackCamera = "back"
    @AppStorage("keepAwake") var keepAwake = true
    @AppStorage("bitrateKbps") var bitrateKbps = 4000
    @AppStorage("codec") var codecPref = "auto"
    @AppStorage("platform") var platformPref = "kick"
    /// auto: only YouTube (enhanced RTMP) and custom servers take the glasses' HEVC untouched. Kick, Restream,
    /// Instagram and TikTok are H.264-only ingests, and Twitch gates HEVC behind Affiliate, so they get a transcode.
    private var codec: String { codecPref == "auto" ? (["youtube", "custom"].contains(platformPref) ? "hevc" : "h264") : codecPref }

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
            Text("Meta: \(streamer.registration)\nGlasses: \(streamer.glassesState)\nDevices: \(streamer.devices)\nRTMP: \(streamer.rtmpState)\nFrames: \(streamer.frames)\nTeam ID: \(streamer.teamID)")
        }
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
                        pill("record.circle.fill", elapsed(ctx.date), .red)
                    }
                    pill("waveform", "\(streamer.fps) fps · \(streamer.kbps) kbps", .white)
                } else {
                    pill("antenna.radiowaves.left.and.right", streamer.rtmpState, .gray)
                }
                Button { tap(); cycleSource() } label: {
                    pill(streamer.source == "phone" ? "iphone" : "eyeglasses",
                         streamer.manualSource == "auto" ? "auto · \(streamer.source)" : streamer.manualSource,
                         streamer.source == "phone" ? .orange : .white)
                }
                .buttonStyle(.plain)
                Button { tap(); streamer.setMuted(!streamer.muted) } label: {
                    pill(streamer.muted ? "mic.slash.fill" : "mic.fill", streamer.muted ? "muted" : "mic", streamer.muted ? .orange : .white)
                }
                .buttonStyle(.plain)
                Button { tap(); streamer.setCameraOff(!streamer.cameraOff) } label: {
                    pill(streamer.cameraOff ? "video.slash.fill" : "video.fill", streamer.cameraOff ? "cam off" : "cam", streamer.cameraOff ? .orange : .white)
                }
                .buttonStyle(.plain)
                Button { tap(); showManager = true } label: {
                    pill("slider.horizontal.3", "manage", .cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    /// auto → glasses → back → front → auto
    private func cycleSource() {
        let order = ["auto", "glasses", "back", "front"]
        let i = order.firstIndex(of: streamer.manualSource) ?? 0
        streamer.setSource(order[(i + 1) % order.count])
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
            roundButton("camera.shutter.button", filled: false) { tap(); streamer.capturePhoto() }
                .disabled(streamer.glassesShort != "streaming")
                .opacity(streamer.glassesShort == "streaming" ? 1 : 0.4)

            Button {
                tap(strong: true)
                if streamer.live {
                    streamer.stopLive()
                } else {
                    streamer.goLive(url: rtmpURL, key: streamKey, micUID: micUID,
                                    fallbackPosition: fallbackCamera == "front" ? .front : .back,
                                    bitrateKbps: bitrateKbps, codec: codec)
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
