import SwiftUI

/// Title / category / viewers / chat / stream key for the connected Kick and Twitch accounts.
struct StreamManagerView: View {
    @EnvironmentObject var platforms: Platforms
    @Environment(\.dismiss) private var dismiss
    @AppStorage("platform") var platformPref = "kick"
    @AppStorage("rtmpURL") var rtmpURL = Platforms.kickIngest
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("chatSite") var chatSite = "kick"
    @AppStorage("chatChannel") var chatChannel = ""

    @State private var tab = "kick"
    @State private var title = ""
    @State private var category: StreamCategory?
    @State private var search = ""
    @State private var results: [StreamCategory] = []
    @State private var chatText = ""
    @State private var busy = false

    private var connected: Bool { tab == "kick" ? platforms.kickConnected : platforms.twitchConnected }

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $tab) { Text("Kick").tag("kick"); Text("Twitch").tag("twitch") }
                    .pickerStyle(.segmented).listRowBackground(Color.clear)
                    .onChange(of: tab) { _, _ in loadFields() }

                if !connected {
                    Section {
                        if tab == "twitch", !platforms.twitchUserCode.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Enter this code on Twitch:").font(.footnote).foregroundStyle(.secondary)
                                Text(platforms.twitchUserCode).font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                                Link("Open \(platforms.twitchVerifyURL)", destination: URL(string: platforms.twitchVerifyURL) ?? URL(string: "https://www.twitch.tv/activate")!)
                                    .font(.footnote)
                            }
                        } else {
                            Button {
                                tab == "kick" ? platforms.connectKick() : platforms.connectTwitch()
                            } label: {
                                Label("Connect \(tab == "kick" ? "Kick" : "Twitch")", systemImage: "link").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } footer: { Text(platforms.status) }
                } else {
                    Section {
                        HStack {
                            Circle().fill(isLive ? .red : .gray).frame(width: 10, height: 10)
                            Text(user).bold()
                            Spacer()
                            Text(isLive ? "\(viewers) viewers" : "offline").foregroundStyle(.secondary)
                            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                        }
                    }

                    Section("Stream info") {
                        TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
                        HStack {
                            Text("Category").foregroundStyle(.secondary)
                            Spacer()
                            Text(category?.name ?? "—").lineLimit(1)
                        }
                        TextField("Search category…", text: $search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: search) { _, q in
                                Task { results = tab == "kick" ? await platforms.kickSearch(q) : await platforms.twitchSearch(q) }
                            }
                        ForEach(results) { c in
                            Button { category = c; search = ""; results = [] } label: {
                                HStack { Text(c.name); Spacer(); if c == category { Image(systemName: "checkmark") } }
                            }
                        }
                        Button {
                            busy = true
                            Task {
                                if tab == "kick" { await platforms.kickApply(title: title, category: category) }
                                else { await platforms.twitchApply(title: title, category: category) }
                                busy = false
                            }
                        } label: {
                            HStack { Spacer(); if busy { ProgressView() } else { Text("Apply title & category").bold() }; Spacer() }
                        }
                        .buttonStyle(.borderedProminent).disabled(busy || title.isEmpty)
                    }

                    Section("Stream key") {
                        HStack {
                            Text(streamKeyValue.isEmpty ? "Not available" : "•••• " + String(streamKeyValue.suffix(4)))
                                .font(.footnote.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Use for streaming") {
                                platformPref = tab
                                rtmpURL = tab == "kick" ? Platforms.kickIngest : Platforms.twitchIngest
                                streamKey = streamKeyValue
                                chatSite = tab
                                if chatChannel.isEmpty { chatChannel = user.lowercased() }
                                platforms.status = "Stream key and chat set for \(tab)"
                            }
                            .disabled(streamKeyValue.isEmpty)
                        }
                    }

                    Section("Send chat") {
                        HStack {
                            TextField("Message", text: $chatText).onSubmit(send)
                            Button(action: send) { Image(systemName: "paperplane.fill") }.disabled(chatText.isEmpty)
                        }
                    }

                    Section {
                        Button("Disconnect \(tab == "kick" ? "Kick" : "Twitch")", role: .destructive) {
                            tab == "kick" ? platforms.disconnectKick() : platforms.disconnectTwitch()
                        }
                    } footer: { Text(platforms.status) }
                }
            }
            .navigationTitle("Stream Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { tab = platformPref == "twitch" ? "twitch" : "kick"; loadFields() }
            .onChange(of: platforms.kickTitle) { _, _ in if tab == "kick" { loadFields() } }
            .onChange(of: platforms.twitchTitle) { _, _ in if tab == "twitch" { loadFields() } }
        }
        .preferredColorScheme(.dark)
    }

    private var user: String { tab == "kick" ? platforms.kickUser : platforms.twitchUser }
    private var isLive: Bool { tab == "kick" ? platforms.kickLive : platforms.twitchLive }
    private var viewers: Int { tab == "kick" ? platforms.kickViewers : platforms.twitchViewers }
    private var streamKeyValue: String { tab == "kick" ? platforms.kickStreamKey : platforms.twitchStreamKey }

    private func loadFields() {
        title = tab == "kick" ? platforms.kickTitle : platforms.twitchTitle
        category = tab == "kick" ? platforms.kickCategory : platforms.twitchCategory
        results = []; search = ""
    }

    private func refresh() async {
        if tab == "kick" { await platforms.refreshKick() } else { await platforms.refreshTwitch() }
        loadFields()
    }

    private func send() {
        let t = chatText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        chatText = ""
        Task { if tab == "kick" { await platforms.kickSend(t) } else { await platforms.twitchSend(t) } }
    }
}
