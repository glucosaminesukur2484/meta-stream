import SwiftUI

/// Title / category / viewers / chat / stream key for the connected accounts.
struct StreamManagerView: View {
    @EnvironmentObject var platforms: Platforms
    @Environment(\.dismiss) private var dismiss
    @AppStorage("platform") var platformPref = "kick"
    @AppStorage("rtmpURL") var rtmpURL = Platforms.kickIngest
    @AppStorage("streamKey") var streamKey = ""
    @AppStorage("chatSite") var chatSite = "kick"
    @AppStorage("chatChannel") var chatChannel = ""
    @AppStorage("restreamChatURL") var restreamChatURL = ""
    @AppStorage("youtubeVideoID") var youtubeVideoID = ""

    @State private var tab = "kick"
    @State private var title = ""
    @State private var category: StreamCategory?
    @State private var search = ""
    @State private var results: [StreamCategory] = []
    @State private var chatText = ""
    @State private var busy = false

    private var name: String { ["kick": "Kick", "twitch": "Twitch", "restream": "Restream", "youtube": "YouTube"][tab] ?? tab }
    private var connected: Bool {
        switch tab { case "kick": platforms.kickConnected; case "twitch": platforms.twitchConnected
                     case "restream": platforms.restreamConnected; default: platforms.ytConnected }
    }
    private var hasApp: Bool { tab == "restream" ? Platforms.hasRestreamApp : tab == "youtube" ? Platforms.hasYouTubeApp : true }
    private var user: String {
        switch tab { case "kick": platforms.kickUser; case "twitch": platforms.twitchUser; case "restream": platforms.restreamUser; default: platforms.ytUser }
    }
    private var isLive: Bool { tab == "kick" ? platforms.kickLive : tab == "twitch" ? platforms.twitchLive : tab == "youtube" ? platforms.ytLive : false }
    private var viewers: Int { tab == "kick" ? platforms.kickViewers : tab == "twitch" ? platforms.twitchViewers : tab == "youtube" ? platforms.ytViewers : 0 }
    private var streamKeyValue: String {
        switch tab { case "kick": platforms.kickStreamKey; case "twitch": platforms.twitchStreamKey
                     case "restream": platforms.restreamStreamKey; default: platforms.ytStreamKey }
    }
    private var ingest: String {
        switch tab { case "kick": Platforms.kickIngest; case "twitch": Platforms.twitchIngest
                     case "restream": Platforms.restreamIngest; default: platforms.ytIngest }
    }
    private var hasCategory: Bool { tab == "kick" || tab == "twitch" }
    private var canSendChat: Bool { tab != "restream" }

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $tab) {
                    Text("Kick").tag("kick"); Text("Twitch").tag("twitch"); Text("Restream").tag("restream"); Text("YouTube").tag("youtube")
                }
                .pickerStyle(.segmented).listRowBackground(Color.clear)
                .onChange(of: tab) { _, _ in loadFields() }

                if !hasApp {
                    Section { Text("This build has no \(name) client ID. Add the RESTREAM_/YOUTUBE_ secrets and rebuild.").foregroundStyle(.secondary) }
                } else if !connected {
                    connectSection
                } else {
                    headerSection
                    infoSection
                    if tab == "restream" { restreamChannelsSection }
                    keySection
                    if canSendChat { chatSection }
                    Section {
                        Button("Disconnect \(name)", role: .destructive) { disconnect() }
                    } footer: { Text(platforms.status) }
                }
            }
            .navigationTitle("Stream Manager")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { tab = ["twitch", "restream", "youtube"].contains(platformPref) ? platformPref : "kick"; loadFields() }
            .onChange(of: platforms.kickTitle) { _, _ in if tab == "kick" { loadFields() } }
            .onChange(of: platforms.twitchTitle) { _, _ in if tab == "twitch" { loadFields() } }
            .onChange(of: platforms.restreamTitle) { _, _ in if tab == "restream" { loadFields() } }
            .onChange(of: platforms.ytTitle) { _, _ in if tab == "youtube" { loadFields() } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: sections

    private var connectSection: some View {
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
                    switch tab {
                    case "kick": platforms.connectKick()
                    case "twitch": platforms.connectTwitch()
                    case "restream": platforms.connectRestream()
                    default: platforms.connectYouTube()
                    }
                } label: { Label("Connect \(name)", systemImage: "link").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            }
        } footer: {
            Text(tab == "youtube" ? "Create the live stream in YouTube Studio first; the app then finds it.\n" + platforms.status : platforms.status)
        }
    }

    private var headerSection: some View {
        Section {
            HStack {
                Circle().fill(isLive ? .red : .gray).frame(width: 10, height: 10)
                Text(user).bold()
                Spacer()
                if tab == "restream" { Text("\(platforms.restreamChannels.filter(\.active).count) destinations").foregroundStyle(.secondary) }
                else { Text(isLive ? "\(viewers) viewers" : "offline").foregroundStyle(.secondary) }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
            }
        }
    }

    private var infoSection: some View {
        Section("Stream info") {
            TextField("Title", text: $title, axis: .vertical).lineLimit(1...3)
            if hasCategory {
                HStack { Text("Category").foregroundStyle(.secondary); Spacer(); Text(category?.name ?? "—").lineLimit(1) }
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
            }
            Button {
                busy = true
                Task {
                    switch tab {
                    case "kick": await platforms.kickApply(title: title, category: category)
                    case "twitch": await platforms.twitchApply(title: title, category: category)
                    case "restream": await platforms.restreamApply(title: title)
                    default: await platforms.ytApply(title: title)
                    }
                    busy = false
                }
            } label: {
                HStack { Spacer(); if busy { ProgressView() } else { Text(hasCategory ? "Apply title & category" : tab == "restream" ? "Apply title to all destinations" : "Apply title").bold() }; Spacer() }
            }
            .buttonStyle(.borderedProminent).disabled(busy || title.isEmpty)
        }
    }

    private var restreamChannelsSection: some View {
        Section("Destinations") {
            ForEach(platforms.restreamChannels) { ch in
                Toggle(ch.name, isOn: Binding(get: { ch.active }, set: { v in Task { await platforms.restreamSetActive(ch, v) } }))
            }
        }
    }

    private var keySection: some View {
        Section("Stream key") {
            HStack {
                Text(streamKeyValue.isEmpty ? "Not available" : "•••• " + String(streamKeyValue.suffix(4)))
                    .font(.footnote.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Use for streaming") {
                    platformPref = tab
                    rtmpURL = ingest
                    streamKey = streamKeyValue
                    chatSite = tab
                    if tab == "restream" { restreamChatURL = platforms.restreamChatURL }
                    if tab == "youtube" { youtubeVideoID = platforms.ytVideoID }
                    if chatChannel.isEmpty, hasCategory { chatChannel = user.lowercased() }
                    platforms.status = "Stream key and chat set for \(name)"
                }
                .disabled(streamKeyValue.isEmpty)
            }
        }
    }

    private var chatSection: some View {
        Section("Send chat") {
            HStack {
                TextField("Message", text: $chatText).onSubmit(send)
                Button(action: send) { Image(systemName: "paperplane.fill") }.disabled(chatText.isEmpty)
            }
        }
    }

    // MARK: actions

    private func loadFields() {
        switch tab {
        case "kick": title = platforms.kickTitle; category = platforms.kickCategory
        case "twitch": title = platforms.twitchTitle; category = platforms.twitchCategory
        case "restream": title = platforms.restreamTitle; category = nil
        default: title = platforms.ytTitle; category = nil
        }
        results = []; search = ""
    }

    private func refresh() async {
        switch tab {
        case "kick": await platforms.refreshKick()
        case "twitch": await platforms.refreshTwitch()
        case "restream": await platforms.refreshRestream()
        default: await platforms.refreshYouTube()
        }
        loadFields()
    }

    private func disconnect() {
        switch tab {
        case "kick": platforms.disconnectKick()
        case "twitch": platforms.disconnectTwitch()
        case "restream": platforms.disconnectRestream()
        default: platforms.disconnectYouTube()
        }
    }

    private func send() {
        let t = chatText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        chatText = ""
        Task {
            switch tab {
            case "kick": await platforms.kickSend(t)
            case "twitch": await platforms.twitchSend(t)
            default: await platforms.ytSend(t)
            }
        }
    }
}
