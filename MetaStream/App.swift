import SwiftUI
import MWDATCore

@main
struct MetaStreamApp: App {
    @StateObject private var streamer = Streamer()
    @StateObject private var platforms = Platforms()

    // ponytail: `try?` swallows a config error into an empty registration status;
    // Streamer's own status strings are where the user will notice something's wrong.
    init() { try? Wearables.configure() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(streamer)
                .environmentObject(platforms)
                .onOpenURL { url in
                    // Meta AI registration/permission callbacks. (Kick OAuth is caught by ASWebAuthenticationSession.)
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
        }
    }
}
