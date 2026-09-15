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
    func updateUIView(_ uiView: WKWebView, context: Context) {
        load(uiView) // no-op if already showing this url
    }
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
    @AppStorage("chatURL") var chatURL = "https://kick.com/popout/YOUR_CHANNEL/chat"
    @AppStorage("glassesMic") var glassesMic = false
    @State private var glassesOn = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewView()
                .frame(height: 260)
                .background(Color.black)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meta: \(streamer.registration) · Glasses: \(streamer.glassesState) · RTMP: \(streamer.rtmpState) · frames \(streamer.frames)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Apple Team ID: \(streamer.teamID)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)

                    TextField("RTMP URL", text: $rtmpURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    SecureField("Stream key", text: $streamKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Chat URL", text: $chatURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                    Toggle("Use glasses mic (8 kHz)", isOn: $glassesMic)

                    HStack {
                        Button("Register with Meta AI") { streamer.register() }
                        Button(glassesOn ? "Stop glasses" : "Start glasses") {
                            glassesOn.toggle()
                            glassesOn ? streamer.startGlasses() : streamer.stopGlasses()
                        }
                        Button(streamer.live ? "Stop" : "Go live") {
                            if streamer.live {
                                streamer.stopLive()
                            } else {
                                streamer.goLive(url: rtmpURL, key: streamKey, glassesMic: glassesMic)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .frame(maxHeight: 220)

            ChatView(url: chatURL)
                .frame(maxHeight: .infinity)
        }
    }
}
