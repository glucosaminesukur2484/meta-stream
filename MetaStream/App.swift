import SwiftUI
import MWDATCore

@main
struct MetaStreamApp: App {
    @StateObject private var streamer = Streamer()

    // ponytail: `try?` swallows a config error into an empty registration status;
    // Streamer's own status strings are where the user will notice something's wrong.
    init() { try? Wearables.configure() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(streamer)
                .onOpenURL { url in
                    Task { _ = try? await Wearables.shared.handleUrl(url) }
                }
        }
    }
}
