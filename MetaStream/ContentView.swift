import SwiftUI
import AVFoundation
import WebKit

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
        load(webView)
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { load(uiView) }
    private func load(_ webView: WKWebView) {
        guard let u = URL(string: url), webView.url?.absoluteString != url else { return }
        webView.load(URLRequest(url: u))
    }
}

struct ContentView: View {
    @EnvironmentObject var streamer: Streamer
    @AppStorage("rtmpURL") var rtmpURL = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    // ponytail: stream key in UserDefaults; move to Keychain if the phone is shared.
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("chatChannel") var chatChannel = ""
    @AppStorage("chatSite") var chatSite = "kick"
    @AppStorage("glassesMic") var glassesMic = false
    @State private var showSettings = false
    @State private var glassesOn = false

    private var chatURL: String {
        chatSite == "twitch"
            ? "https://www.twitch.tv/popout/\(chatChannel)/chat"
            : "https://kick.com/popout/\(chatChannel)/chat"
    }

    var body: some View {
        VStack(spacing: 8) {
            PreviewView()
                .frame(height: 200)
                .background(Color.black)

            VStack(alignment: .leading, spacing: 2) {
                Text("Meta: \(streamer.registration)   Glasses: \(streamer.glassesState)")
                Text("RTMP: \(streamer.rtmpState)   frames: \(streamer.frames)")
                Text("Apple Team ID: \(streamer.teamID)")
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            HStack(spacing: 8) {
                Button("1. Register") { streamer.register() }
                Button(glassesOn ? "Stop glasses" : "2. Glasses") {
                    glassesOn.toggle()
                    glassesOn ? streamer.startGlasses() : streamer.stopGlasses()
                }
                Button(streamer.live ? "Stop live" : "3. Go live") {
                    streamer.live ? streamer.stopLive()
                        : streamer.goLive(url: rtmpURL, key: streamKey, glassesMic: glassesMic)
                }
                .tint(streamer.live ? .red : .green)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)

            DisclosureGroup("Settings", isExpanded: $showSettings) {
                VStack(spacing: 8) {
                    TextField("RTMP URL", text: $rtmpURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Stream key", text: $streamKey)
                    HStack {
                        Picker("Chat", selection: $chatSite) {
                            Text("Kick").tag("kick"); Text("Twitch").tag("twitch")
                        }.pickerStyle(.segmented).frame(width: 140)
                        TextField("channel name", text: $chatChannel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Toggle("Use glasses mic (8 kHz)", isOn: $glassesMic)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 4)
            }
            .padding(.horizontal)

            if chatChannel.isEmpty {
                Text("Open Settings and enter your channel name to see chat here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatView(url: chatURL).frame(maxHeight: .infinity)
            }
        }
        .padding(.top, 4)
    }
}
