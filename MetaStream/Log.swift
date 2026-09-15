import Foundation
import os
import SwiftUI

/// One log for everything: mirrored to the device console (os_log, public) and kept in memory for the Logs screen.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published private(set) var text = ""
    private var lines: [String] = []
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    func add(_ line: String) {
        lines.append(Self.fmt.string(from: Date()) + " " + line)
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }   // ponytail: ring buffer by trimming
        text = lines.joined(separator: "\n")
    }
    func clear() { lines = []; text = "" }
}

private let loggers: [String: Logger] = ["api", "stream", "glasses", "auth", "ui"].reduce(into: [:]) {
    $0[$1] = Logger(subsystem: "com.saeedkolivand.metastream", category: $1)
}

/// Masks values of JSON/query fields that look like credentials before they reach the log or the console.
/// Covers stream keys (Kick `key`, Twitch `stream_key`, Restream `streamKey`, YouTube `streamName`) and OAuth material.
private let secretField = try! NSRegularExpression(
    pattern: #"("(?:[a-zA-Z_]*(?:key|token|secret|password|authorization|streamName)[a-zA-Z_]*)"\s*:\s*")([^"]*)(")"#,
    options: [.caseInsensitive])
func redact(_ s: String) -> String {
    secretField.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1***$3")
}

/// `applog("api", "GET …")` from any thread. Bodies must go through `redact` first; never pass raw tokens or keys.
func applog(_ category: String, _ message: String, error: Bool = false) {
    let l = loggers[category] ?? loggers["ui"]!
    if error { l.error("\(message, privacy: .public)") } else { l.info("\(message, privacy: .public)") }
    Task { @MainActor in LogStore.shared.add("[\(category)] \(message)") }
}

struct LogView: View {
    @ObservedObject var store = LogStore.shared
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(store.text.isEmpty ? "No log lines yet." : store.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .id("end")
            }
            .onChange(of: store.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ShareLink(item: store.text) { Image(systemName: "square.and.arrow.up") } }
            ToolbarItem(placement: .cancellationAction) { Button("Clear") { store.clear() } }
        }
    }
}
