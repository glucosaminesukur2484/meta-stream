import SwiftUI

/// Title / category / viewers / chat / stream key for the connected accounts.
struct StreamManagerView: View {
    @EnvironmentObject var platforms: Platforms
    @Environment(\.dismiss) private var dismiss
    @AppStorage("platform") var platformPref = "kick"
    @AppStorage("rtmpURL") var ingestURL = Platforms.kickIngest
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
    // Twitch hands-free actions
    @State private var announceText = ""
    @State private var raidTarget = ""

    // Kick + Twitch
    @State private var tags = ""              // comma-separated
    // Twitch only
    @State private var labels: [String: Bool] = [:]
    @State private var delay = 0
    @State private var language = ""
    // YouTube only
    @State private var description = ""
    @State private var privacy = "public"
    @State private var latency = "normal"

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
    /// Kick's channel response carries a per-account stream.url (see Platforms.refreshKick's kickStreamURL) --
    /// prefer it over the constant, same as ytIngest already does for YouTube; empty (not yet fetched, or the
    /// call failed) falls back to the published default. Twitch and Restream don't hand back a per-account
    /// ingest anywhere in this app's API usage, so those stay on their constants.
    private var ingest: String {
        switch tab {
        case "kick": platforms.kickStreamURL.isEmpty ? Platforms.kickIngest : platforms.kickStreamURL
        case "twitch": Platforms.twitchIngest
        case "restream": Platforms.restreamIngest
        default: platforms.ytIngest
        }
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
                    if tab == "twitch" { twitchActionsSection }
                    infoSection
                    if tab == "restream" { restreamDestinationsSection }
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
                } label: {
                    HStack { Spacer(); Image(systemName: "link"); Text("Connect \(name)").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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
                if tab == "restream" { Text("\(platforms.restreamDestinations.filter(\.active).count)/\(platforms.restreamDestinations.count) destinations").foregroundStyle(.secondary) }
                else { Text(isLive ? "\(viewers) viewers" : "offline").foregroundStyle(.secondary) }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
            }
        }
    }

    /// Hands-free Twitch actions: one decisive tap each, no screen reading required to use them (the glasses
    /// use case this app exists for). Each control disables itself with a reason when its write scope hasn't
    /// been granted yet, instead of failing at tap time with a 401 — see Platforms.twitchActionScopes.
    private var twitchActionsSection: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    Task {
                        do { let c = try await platforms.twitchCreateClip(); platforms.status = "Clip created: \(c.url)" }
                        catch { platforms.status = error.localizedDescription }
                    }
                } label: {
                    VStack(spacing: 4) { Image(systemName: "scissors").font(.title2); Text("Clip").bold() }.frame(maxWidth: .infinity)
                }
                .disabled(!platforms.twitchHasScopes(Platforms.twitchActionScopes["clips"]!))

                Button {
                    Task {
                        do { try await platforms.twitchCreateMarker(); platforms.status = "Marker set" }
                        catch { platforms.status = error.localizedDescription }
                    }
                } label: {
                    VStack(spacing: 4) { Image(systemName: "bookmark.fill").font(.title2); Text("Marker").bold() }.frame(maxWidth: .infinity)
                }
                .disabled(!platforms.twitchHasScopes(["channel:manage:broadcast"]))
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .listRowInsets(EdgeInsets()).padding(.vertical, 4)

            HStack {
                Text("Next ad").foregroundStyle(.secondary)
                Spacer()
                if let next = platforms.twitchAdNextAt { Text(next, style: .relative) } else { Text("unknown") }
            }
            Button("Snooze ad (\(platforms.twitchAdSnoozeCount) left)") { Task { await platforms.twitchSnoozeAd() } }
                .disabled(!platforms.twitchHasScopes(Platforms.twitchActionScopes["ads"]!) || platforms.twitchAdSnoozeCount == 0)

            Button("Start 90s commercial") { Task { await platforms.twitchStartCommercial() } }
                .disabled(!platforms.twitchHasScopes(Platforms.twitchActionScopes["commercial"]!))

            HStack {
                Text("Chat lockdown").foregroundStyle(.secondary)
                Spacer()
                Button("Lock") { Task { await platforms.twitchLockdownChat(on: true) } }
                Button("Unlock") { Task { await platforms.twitchLockdownChat(on: false) } }
            }
            .disabled(!platforms.twitchHasScopes(Platforms.twitchActionScopes["chat lockdown"]!))

            HStack {
                TextField("Announcement", text: $announceText)
                Button("Send") { let t = announceText; announceText = ""; Task { await platforms.twitchAnnounce(t) } }
                    .disabled(announceText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!platforms.twitchHasScopes(Platforms.twitchActionScopes["announcements"]!))

            HStack {
                TextField("Raid channel", text: $raidTarget).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Raid") { let t = raidTarget; raidTarget = ""; Task { await platforms.twitchRaid(t) } }
                    .disabled(raidTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(!platforms.twitchHasScopes(Platforms.twitchActionScopes["raids"]!))
        } header: { Text("Quick actions") } footer: {
            if !platforms.twitchMissingScopeFeatures.isEmpty {
                Text("Disconnect and reconnect Twitch below to enable \(platforms.twitchMissingScopeFeatures.joined(separator: ", ")).")
                    .foregroundStyle(.orange)
            } else {
                Text("Moderation (delete/timeout/ban) is available from chat message rows.")
            }
        }
    }

    private var infoSection: some View {
        Section {
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
            if tab == "kick" || tab == "twitch" {
                TextField("Tags, comma separated", text: $tags)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if tab == "twitch" {
                TextField("Language (e.g. en)", text: $language)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Stepper("Stream delay: \(delay)s", value: $delay, in: 0...900, step: 15)
                ForEach(twitchLabelOptions, id: \.id) { opt in
                    Toggle(opt.name, isOn: Binding(get: { labels[opt.id] ?? false }, set: { labels[opt.id] = $0 }))
                }
            }
            if tab == "youtube" {
                TextField("Description", text: $description, axis: .vertical).lineLimit(1...4)
                Picker("Privacy", selection: $privacy) {
                    Text("Public").tag("public"); Text("Unlisted").tag("unlisted"); Text("Private").tag("private")
                }
                Picker("Latency", selection: $latency) {
                    Text("Normal").tag("normal"); Text("Low").tag("low"); Text("Ultra-low").tag("ultraLow")
                }
            }
            Button {
                busy = true
                let cleanTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                Task {
                    switch tab {
                    case "kick": await platforms.kickApply(title: title, category: category, tags: cleanTags)
                    case "twitch": await platforms.twitchApply(title: title, category: category, tags: cleanTags, labels: labels, delay: delay, language: language)
                    case "restream": await platforms.restreamApply(title: title)
                    default: await platforms.ytApply(title: title, description: description, privacy: privacy, latency: latency)
                    }
                    busy = false
                }
            } label: {
                HStack { Spacer(); if busy { ProgressView() } else { Text(tab == "restream" ? "Apply title to all destinations" : "Apply changes").bold() }; Spacer() }
            }
            .buttonStyle(.borderedProminent).disabled(busy || title.isEmpty)
        } header: { Text("Stream info") } footer: {
            if tab == "twitch" { Text("Stream delay is Partner-only — Twitch ignores or errors it otherwise. It's the anti-stream-sniping delay, worth it for IRL.") }
        }
    }

    /// The real label set (id, human name) from Platforms.fetchTwitchLabelCatalog() once it's loaded;
    /// Self.twitchLabelIDs + labelName() below while it's still empty (not yet fetched, or the call
    /// failed) -- see that function's doc for why empty is the safe default rather than blocking on it.
    private var twitchLabelOptions: [(id: String, name: String)] {
        platforms.twitchLabelCatalog.isEmpty
            ? Platforms.twitchLabelIDs.map { ($0, Self.labelName($0)) }
            : platforms.twitchLabelCatalog
    }

    /// Fallback names for Self.twitchLabelIDs, used only while twitchLabelOptions hasn't got a fetched
    /// catalog yet.
    private static func labelName(_ id: String) -> String {
        switch id {
        case "DebatedSocialIssuesAndPolitics": return "Debated social issues & politics"
        case "DrugsIntoxication": return "Drugs, intoxication"
        case "SexualThemes": return "Sexual themes"
        case "ViolentGraphic": return "Violent & graphic"
        case "Gambling": return "Gambling"
        case "ProfanityVulgarity": return "Profanity & vulgarity"
        default: return id
        }
    }

    private var restreamDestinationsSection: some View {
        Section {
            ForEach(platforms.restreamDestinations) { ch in
                Toggle(isOn: Binding(get: { ch.active }, set: { v in Task { await platforms.restreamSetActive(ch, v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ch.name)
                        Text(ch.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        } header: { Text("Destinations") } footer: {
            Text("Turning one off stops Restream sending there on your next stream. Add new destinations in the Restream dashboard.")
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
                    ingestURL = ingest
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
        case "kick":
            title = platforms.kickTitle; category = platforms.kickCategory
            tags = platforms.kickTags.joined(separator: ", ")
        case "twitch":
            title = platforms.twitchTitle; category = platforms.twitchCategory
            tags = platforms.twitchTags.joined(separator: ", ")
            labels = Dictionary(uniqueKeysWithValues: twitchLabelOptions.map { ($0.id, platforms.twitchLabels.contains($0.id)) })
            delay = platforms.twitchDelay
            language = platforms.twitchLanguage
        case "restream":
            title = platforms.restreamTitle; category = nil
        default:
            title = platforms.ytTitle; category = nil
            description = platforms.ytDescription; privacy = platforms.ytPrivacy; latency = platforms.ytLatency
        }
        results = []; search = ""
    }

    private func refresh() async {
        switch tab {
        case "kick": await platforms.refreshKick()
        case "twitch":
            await platforms.refreshTwitch()
            await platforms.fetchTwitchLabelCatalog()   // real label set + names; see twitchLabelOptions
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
