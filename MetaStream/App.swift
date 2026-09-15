import SwiftUI
import MWDATCore

@main
struct MetaStreamApp: App {
    @StateObject private var streamer = Streamer()
    @StateObject private var platforms = Platforms()
    @StateObject private var speaker = Speaker()
    @StateObject private var chat = ChatFeed()

    // ponytail: `try?` swallows a config error into an empty registration status;
    // Streamer's own status strings are where the user will notice something's wrong.
    init() { try? Wearables.configure() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(streamer)
                .environmentObject(platforms)
                .environmentObject(speaker)
                .environmentObject(chat)
                // Streamer speaks connection changes on Speaker's System lane (never muted).
                .onAppear { streamer.speaker = speaker }
                .onOpenURL { url in
                    // Meta AI registration/permission callbacks. (Kick OAuth is caught by ASWebAuthenticationSession.)
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
        }
    }
}
