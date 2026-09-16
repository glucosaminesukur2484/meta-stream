import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import os

struct StreamCategory: Identifiable, Hashable { let id: String; let name: String }
struct RestreamDestination: Identifiable, Hashable { let id: Int; let name: String; let url: String; var active: Bool }

/// Kick, Twitch, Restream, YouTube accounts: login, channel info (title/category/viewers), chat send, stream key.
/// ponytail: tokens live in UserDefaults; move to Keychain if the phone is shared.
@MainActor
final class Platforms: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var status = "" { didSet { applog("api", "status: \(status)") } }

    // Kick
    @Published var kickUser = ""
    @Published var kickTitle = ""
    @Published var kickCategory: StreamCategory?
    @Published var kickLive = false
    @Published var kickViewers = 0
    @Published var kickStreamURL = ""
    @Published var kickStreamKey = ""
    @Published var kickTags: [String] = []    // custom_tags; no confirmed read-back field, so this only tracks what we last sent
    private var kickUserID = 0

    // Twitch
    @Published var twitchUser = ""
    @Published var twitchTitle = ""
    @Published var twitchCategory: StreamCategory?
    @Published var twitchLive = false
    @Published var twitchViewers = 0
    @Published var twitchStreamKey = ""
    @Published var twitchUserCode = ""        // shown while the device-code login is pending
    @Published var twitchVerifyURL = ""
    @Published var twitchTags: [String] = []
    @Published var twitchLabels: Set<String> = []     // enabled content_classification_labels
    @Published var twitchDelay = 0                    // seconds; Partner-only stream delay
    @Published var twitchLanguage = ""
    @Published private(set) var twitchScopes: Set<String> = []   // granted at last auth; see twitchHasScopes
    @Published var twitchAdNextAt: Date?          // nil until a schedule fetch succeeds (needs channel:read:ads)
    @Published var twitchAdSnoozeCount = 0
    /// Fetched from an authenticated helix/users call. Readable so Emotes can ask 7TV/BTTV/FFZ for this
    /// channel's sets without going round Twitch's undocumented web GQL for an ID we already hold.
    private(set) var twitchUserID = ""
    // https://dev.twitch.tv/docs/api/reference/#get-content-classification-labels — the current valid CCL ids.
    // Fallback set for when fetchTwitchLabelCatalog() hasn't run yet or failed -- see twitchLabelCatalog.
    static let twitchLabelIDs = ["DebatedSocialIssuesAndPolitics", "DrugsIntoxication", "SexualThemes", "ViolentGraphic", "Gambling", "ProfanityVulgarity"]
    /// The real, current label set with human names, from GET helix/content_classification_labels -- see
    /// fetchTwitchLabelCatalog(). Empty until that call succeeds; StreamManagerView falls back to
    /// twitchLabelIDs + its own labelName() switch while this is empty.
    @Published private(set) var twitchLabelCatalog: [(id: String, name: String)] = []
    // Read scopes the chat feed's EventSub subscriptions need, keyed by the feature name the UI shows.
    // user:read:chat has shipped since the first Twitch connect, so old tokens already carry it; the other
    // three are new as of chat-feed support, so an existing user's token won't have them until they reconnect.
    static let twitchChatScopes: [String: Set<String>] = [
        "chat": ["user:read:chat"],
        "follows": ["moderator:read:followers"],
        "subscriptions": ["channel:read:subscriptions"],
        "cheers": ["bits:read"],
    ]
    // Write scopes for hands-free broadcaster actions (Phase 1c) — the second and final re-auth milestone.
    // Same "reconnect once" pattern as twitchChatScopes. Stream markers use channel:manage:broadcast, which
    // Phase 1a already requested for title/category edits, so that action needs no new scope and has no
    // entry here — see twitchCreateMarker.
    static let twitchActionScopes: [String: Set<String>] = [
        "clips": ["clips:edit"],
        "ads": ["channel:read:ads", "channel:manage:ads"],
        "commercial": ["channel:edit:commercial"],
        "chat lockdown": ["moderator:manage:chat_settings"],
        "announcements": ["moderator:manage:announcements"],
        "raids": ["channel:manage:raids"],
        "moderation": ["moderator:manage:chat_messages", "moderator:manage:banned_users"],
    ]

    // Restream
    @Published var restreamUser = ""
    @Published var restreamDestinations: [RestreamDestination] = []
    @Published var restreamTitle = ""
    @Published var restreamStreamKey = ""
    @Published var restreamChatURL = ""

    // YouTube
    @Published var ytUser = ""
    @Published var ytTitle = ""
    @Published var ytDescription = ""
    @Published var ytPrivacy = "public"       // public / unlisted / private
    @Published var ytLatency = "normal"       // normal / low / ultraLow
    @Published var ytLive = false
    @Published var ytViewers = 0
    @Published var ytVideoID = ""
    @Published var ytStreamKey = ""
    @Published var ytIngest = "rtmps://a.rtmps.youtube.com:443/live2"
    private var ytLiveChatID = ""
    private var ytBroadcast: [String: Any] = [:]

    private var authSession: ASWebAuthenticationSession?
    private let d = UserDefaults.standard
    private static let info = Bundle.main.infoDictionary ?? [:]
    private static let kickID = info["KickClientID"] as? String ?? ""
    private static let kickSecret = info["KickClientSecret"] as? String ?? ""
    private static let twitchID = info["TwitchClientID"] as? String ?? ""
    private static let restreamID = info["RestreamClientID"] as? String ?? ""
    private static let restreamSecret = info["RestreamClientSecret"] as? String ?? ""
    private static let youtubeID = info["YouTubeClientID"] as? String ?? ""
    static let webRedirect = "https://metastream.iamsaeed.dev/oauth.html"   // GitHub Pages (docs/) → metastream:// scheme
    static let googleRedirect = "com.saeedkolivand.metastream:/oauth2redirect" // Google iOS clients accept the bundle-id scheme
    static let kickIngest = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    static let twitchIngest = "rtmps://live.twitch.tv:443/app/"
    static let restreamIngest = "rtmp://live.restream.io/live"   // Restream serves plain RTMP on 1935 (RTMPS on 443 hangs the handshake)

    var kickConnected: Bool { d.string(forKey: "kickAccess") != nil }
    var twitchConnected: Bool { d.string(forKey: "twitchAccess") != nil }
    var restreamConnected: Bool { d.string(forKey: "restreamAccess") != nil }
    var ytConnected: Bool { d.string(forKey: "ytAccess") != nil }
    static var hasRestreamApp: Bool { !restreamID.isEmpty }
    static var hasYouTubeApp: Bool { !youtubeID.isEmpty }

    override init() {
        super.init()
        twitchScopes = Set(d.stringArray(forKey: "twitchScopes") ?? [])
        if kickConnected { Task { await refreshKick() } }
        if twitchConnected { Task { await refreshTwitch() } }
        if restreamConnected { Task { await refreshRestream() } }
        if ytConnected { Task { await refreshYouTube() } }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    /// Opens the system auth sheet and hands back the `code` query item (nil if cancelled).
    private func authorize(_ url: URL, scheme: String) async -> String? {
        await withCheckedContinuation { cont in
            applog("auth", "authorize \(url.host ?? "?")\(url.path) scheme=\(scheme)")
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                let code = items.first(where: { $0.name == "code" })?.value
                applog("auth", "callback url=\(url?.host ?? "nil")\(url?.path ?? "") params=\(items.map(\.name)) code=\(code == nil ? "missing" : "ok") error=\(error.map { String(describing: $0) } ?? "none")", error: code == nil)
                cont.resume(returning: code)
            }
            s.presentationContextProvider = self
            authSession = s
            s.start()
        }
    }

    // MARK: - Kick (OAuth 2.1 + PKCE, client secret on token exchange)

    func connectKick() {
        Task {
            let verifier = Self.random(64)
            var c = URLComponents(string: "https://id.kick.com/oauth/authorize")!
            c.queryItems = [
                .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.kickID),
                .init(name: "redirect_uri", value: Self.webRedirect),
                .init(name: "scope", value: "user:read channel:read channel:write chat:write streamkey:read"),
                .init(name: "code_challenge", value: Self.s256(verifier)), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: Self.random(16)),
            ]
            guard let code = await authorize(c.url!, scheme: "metastream") else { status = "Kick login cancelled"; return }
            do {
                let json = try await Self.form("https://id.kick.com/oauth/token", [
                    "grant_type": "authorization_code", "client_id": Self.kickID, "client_secret": Self.kickSecret,
                    "redirect_uri": Self.webRedirect, "code_verifier": verifier, "code": code])
                try saveTokens(json, prefix: "kick")
                status = "Kick connected"
                await refreshKick()
            } catch { status = "Kick token error: \(error.localizedDescription)" }
        }
    }

    private func kick(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        try await call(method, "https://api.kick.com" + path, query: query, body: body, tokenKey: "kickAccess") {
            let json = try await Self.form("https://id.kick.com/oauth/token", [
                "grant_type": "refresh_token", "client_id": Self.kickID, "client_secret": Self.kickSecret,
                "refresh_token": self.d.string(forKey: "kickRefresh") ?? ""])
            try self.saveTokens(json, prefix: "kick")
        }
    }

    func refreshKick() async {
        do {
            if let u = ((try await kick("GET", "/public/v1/users"))["data"] as? [[String: Any]])?.first {
                kickUserID = u["user_id"] as? Int ?? 0
                kickUser = u["name"] as? String ?? ""
            }
            if let ch = ((try await kick("GET", "/public/v1/channels"))["data"] as? [[String: Any]])?.first {
                kickTitle = ch["stream_title"] as? String ?? ""
                if let cat = ch["category"] as? [String: Any], let id = cat["id"] as? Int {
                    kickCategory = StreamCategory(id: String(id), name: cat["name"] as? String ?? "")
                }
                let st = ch["stream"] as? [String: Any] ?? [:]
                kickLive = st["is_live"] as? Bool ?? false
                kickViewers = st["viewer_count"] as? Int ?? 0
                kickStreamKey = st["key"] as? String ?? ""
                kickStreamURL = st["url"] as? String ?? ""
                if kickUser.isEmpty { kickUser = ch["slug"] as? String ?? "" }
            }
            status = "Kick updated"
        } catch { status = error.localizedDescription }
    }

    func kickSearch(_ q: String) async -> [StreamCategory] {
        guard q.count >= 3 else { return [] }
        let r = try? await kick("GET", "/public/v2/categories", query: [.init(name: "name", value: q), .init(name: "limit", value: "8")])
        return ((r?["data"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? Int else { return nil }
            return StreamCategory(id: String(id), name: $0["name"] as? String ?? "")
        }
    }

    func kickApply(title: String, category: StreamCategory?, tags: [String] = []) async {
        var body: [String: Any] = ["stream_title": title]
        if let category, let id = Int(category.id) { body["category_id"] = id }
        let cleanTags = Array(tags.prefix(10))                          // Kick caps custom_tags at 10
        if cleanTags != kickTags { body["custom_tags"] = cleanTags }    // omit when unchanged: an empty/unloaded field must not wipe real tags
        do {
            _ = try await kick("PATCH", "/public/v1/channels", body: body)
            if body["custom_tags"] != nil { kickTags = cleanTags }
            status = "Kick title updated"; await refreshKick()
        } catch { status = error.localizedDescription }
    }

    func kickSend(_ text: String) async {
        do { _ = try await kick("POST", "/public/v1/chat", body: ["content": text, "type": "user", "broadcaster_user_id": kickUserID]) }
        catch { status = error.localizedDescription }
    }

    func disconnectKick() { forget("kick"); kickUser = ""; kickTitle = ""; kickCategory = nil; kickStreamKey = ""; kickTags = [] }

    // MARK: - Twitch (Device Code Grant, public client, no secret)

    func connectTwitch() {
        Task {
            do {
                // moderator:read:followers / channel:read:subscriptions / bits:read are read-only additions for
                // the chat feed (follow/subscribe/cheer alerts, Phase 1b). clips:edit / channel:read:ads /
                // channel:manage:ads / channel:edit:commercial / moderator:manage:chat_settings /
                // moderator:manage:announcements / channel:manage:raids / moderator:manage:chat_messages /
                // moderator:manage:banned_users are the write scopes for hands-free broadcaster actions
                // (Phase 1c) — the second and final re-auth milestone; see twitchActionScopes.
                let scopes = "channel:manage:broadcast channel:read:stream_key user:write:chat user:read:chat moderator:read:followers channel:read:subscriptions bits:read clips:edit channel:read:ads channel:manage:ads channel:edit:commercial moderator:manage:chat_settings moderator:manage:announcements channel:manage:raids moderator:manage:chat_messages moderator:manage:banned_users"
                let dev = try await Self.form("https://id.twitch.tv/oauth2/device", ["client_id": Self.twitchID, "scopes": scopes])
                guard let deviceCode = dev["device_code"] as? String else { throw Self.err("no device_code: \(dev)") }
                twitchUserCode = dev["user_code"] as? String ?? ""
                twitchVerifyURL = dev["verification_uri"] as? String ?? "https://www.twitch.tv/activate"
                let interval = max(dev["interval"] as? Int ?? 5, 5)
                status = "Enter code \(twitchUserCode) on Twitch"
                if let u = URL(string: twitchVerifyURL) { await UIApplication.shared.open(u) }
                for _ in 0..<(900 / interval) {                        // ponytail: 15 min ceiling
                    try await Task.sleep(for: .seconds(interval))
                    let r = try await Self.form("https://id.twitch.tv/oauth2/token", [
                        "client_id": Self.twitchID, "scopes": scopes, "device_code": deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code"], allowError: true)
                    if r["access_token"] != nil {
                        try saveTokens(r, prefix: "twitch")
                        twitchUserCode = ""
                        status = "Twitch connected"
                        await refreshTwitch()
                        return
                    }
                    if (r["message"] as? String) != "authorization_pending" { throw Self.err("Twitch: \(r["message"] ?? r)") }
                }
                status = "Twitch login timed out"
            } catch { status = error.localizedDescription; twitchUserCode = "" }
        }
    }

    private func helix(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        try await call(method, "https://api.twitch.tv/helix" + path, query: query, body: body, tokenKey: "twitchAccess",
                       headers: ["Client-Id": Self.twitchID]) {
            let json = try await Self.form("https://id.twitch.tv/oauth2/token", [
                "grant_type": "refresh_token", "client_id": Self.twitchID, "refresh_token": self.d.string(forKey: "twitchRefresh") ?? ""])
            try self.saveTokens(json, prefix: "twitch")
        }
    }

    func refreshTwitch() async {
        do {
            if let u = ((try await helix("GET", "/users"))["data"] as? [[String: Any]])?.first {
                twitchUserID = u["id"] as? String ?? ""
                twitchUser = u["display_name"] as? String ?? u["login"] as? String ?? ""
            }
            let bid = [URLQueryItem(name: "broadcaster_id", value: twitchUserID)]
            if let ch = ((try await helix("GET", "/channels", query: bid))["data"] as? [[String: Any]])?.first {
                twitchTitle = ch["title"] as? String ?? ""
                if let gid = ch["game_id"] as? String, !gid.isEmpty {
                    twitchCategory = StreamCategory(id: gid, name: ch["game_name"] as? String ?? "")
                }
                twitchTags = ch["tags"] as? [String] ?? []
                twitchLabels = Set(ch["content_classification_labels"] as? [String] ?? [])
                twitchDelay = ch["delay"] as? Int ?? 0
                twitchLanguage = ch["broadcaster_language"] as? String ?? ""
            }
            let live = ((try await helix("GET", "/streams", query: [.init(name: "user_id", value: twitchUserID)]))["data"] as? [[String: Any]])?.first
            twitchLive = live != nil
            twitchViewers = live?["viewer_count"] as? Int ?? 0
            if let k = ((try await helix("GET", "/streams/key", query: bid))["data"] as? [[String: Any]])?.first {
                twitchStreamKey = k["stream_key"] as? String ?? ""
            }
            if twitchHasScopes(["channel:read:ads"]) { await twitchRefreshAdSchedule() }
            status = "Twitch updated"
        } catch { status = error.localizedDescription }
    }

    func twitchSearch(_ q: String) async -> [StreamCategory] {
        guard q.count >= 2 else { return [] }
        let r = try? await helix("GET", "/search/categories", query: [.init(name: "query", value: q), .init(name: "first", value: "8")])
        return ((r?["data"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return StreamCategory(id: id, name: $0["name"] as? String ?? "")
        }
    }

    /// GET helix/content_classification_labels -- the current, real label set with human names, so a label
    /// Twitch adds later shows up in StreamManagerView without a code change, instead of only ever offering
    /// Self.twitchLabelIDs' fixed six. `name`/`description` are the documented response fields (confirmed
    /// against Twitch's published schema); falls back to `description` then the raw id if `name` is somehow
    /// missing, so a row is never blank. Cached per session (guard on non-empty) -- this needs no
    /// broadcaster_id and doesn't change while the app is running, so there's nothing to gain re-fetching on
    /// every refreshTwitch(). Left empty (not overwritten with a partial/failed result) on any error or an
    /// empty response, so callers fall back to Self.twitchLabelIDs + StreamManagerView.labelName() --
    /// no network yet is a known-good default, not a blank picker.
    func fetchTwitchLabelCatalog() async {
        guard twitchLabelCatalog.isEmpty else { return }
        guard let data = (try? await helix("GET", "/content_classification_labels"))?["data"] as? [[String: Any]] else { return }
        let parsed = data.compactMap { item -> (id: String, name: String)? in
            guard let id = item["id"] as? String else { return nil }
            return (id, (item["name"] as? String) ?? (item["description"] as? String) ?? id)
        }
        guard !parsed.isEmpty else { return }
        twitchLabelCatalog = parsed
    }

    /// `tags`/`labels`/`delay`/`language` are all "omit when unchanged" against the last-loaded values, so an
    /// untouched (or not-yet-loaded) field can never silently wipe what's already on the channel.
    func twitchApply(title: String, category: StreamCategory?, tags: [String] = [], labels: [String: Bool] = [:], delay: Int = 0, language: String = "") async {
        var body: [String: Any] = ["title": title]
        if let category { body["game_id"] = category.id }

        // ponytail: drop invalid tags instead of 400ing — no spaces, ≤25 chars, ≤10 tags (Twitch's own limits).
        let cleanTags = Array(tags.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && $0.count <= 25 }.prefix(10))
        if cleanTags != twitchTags { body["tags"] = cleanTags }

        // Keyed off `labels`' own keys (whatever StreamManagerView showed toggles for -- the fetched
        // catalog when available, Self.twitchLabelIDs otherwise), not the hardcoded id list directly, so a
        // label the catalog added actually gets sent instead of silently staying whatever it was.
        let currentLabels = twitchLabels.intersection(labels.keys)
        let newLabels = Set(labels.filter(\.value).keys)
        if newLabels != currentLabels {
            body["content_classification_labels"] = labels.keys.map { ["id": $0, "is_enabled": newLabels.contains($0)] }
        }

        if delay != twitchDelay { body["delay"] = delay }   // Partner-only anti-stream-sniping delay; Twitch ignores/errors it for everyone else

        let lang = language.trimmingCharacters(in: .whitespaces)
        if !lang.isEmpty, lang != twitchLanguage { body["broadcaster_language"] = lang }

        do {
            _ = try await helix("PATCH", "/channels", query: [.init(name: "broadcaster_id", value: twitchUserID)], body: body)
            status = "Twitch channel updated"; await refreshTwitch()
        } catch { status = error.localizedDescription }
    }

    func twitchSend(_ text: String) async {
        do { _ = try await helix("POST", "/chat/messages", body: ["broadcaster_id": twitchUserID, "sender_id": twitchUserID, "message": text]) }
        catch { status = error.localizedDescription }
    }

    func disconnectTwitch() {
        forget("twitch"); twitchUser = ""; twitchTitle = ""; twitchCategory = nil; twitchStreamKey = ""
        twitchTags = []; twitchLabels = []; twitchDelay = 0; twitchLanguage = ""; twitchScopes = []
        twitchAdNextAt = nil; twitchAdSnoozeCount = 0
    }

    /// True when every scope in `required` was granted at the last Twitch auth. Adding a scope never upgrades
    /// an existing token and refreshing doesn't either, so callers check this before using a scoped feature
    /// instead of discovering it's missing as a 401.
    func twitchHasScopes(_ required: Set<String>) -> Bool { required.isSubset(of: twitchScopes) }

    /// Feature names (keys of `twitchChatScopes` + `twitchActionScopes`) whose scope is missing from the
    /// currently granted set — empty once the user reconnects. For the UI to render a "Reconnect Twitch"
    /// prompt naming just the affected features; nothing here disconnects the user or triggers re-auth on
    /// its own. Device-code login has a fixed 15-minute ceiling and needs the user present, so it's the
    /// UI's call when to ask, never automatic at launch or mid-stream.
    var twitchMissingScopeFeatures: [String] { Self.missingScopeFeatures(granted: twitchScopes) }

    /// Pure version of the above (no `self`), so the scope-gap logic can be exercised without a live
    /// `Platforms` instance — see `demo()`.
    static func missingScopeFeatures(granted: Set<String>) -> [String] {
        twitchChatScopes.merging(twitchActionScopes) { a, _ in a }
            .filter { !$0.value.isSubset(of: granted) }.map(\.key).sorted()
    }

    #if DEBUG
    /// Self-check for the scope-gap logic: given a granted scope set, the right feature names come back
    /// as missing. This is the logic a user actually feels when a button is greyed out.
    static func demo() {
        let granted: Set<String> = ["channel:manage:broadcast", "user:read:chat", "clips:edit", "channel:read:ads", "channel:manage:ads"]
        let missing = missingScopeFeatures(granted: granted)
        let want = ["announcements", "chat lockdown", "cheers", "commercial", "follows", "moderation", "raids", "subscriptions"]
        assert(missing == want, "twitch scope-gap mismatch: got \(missing), want \(want)")
        assert(missingScopeFeatures(granted: []).count == twitchChatScopes.count + twitchActionScopes.count, "empty grant should miss every feature")
        applog("api", "Platforms.demo: scope-gap check ok")
    }
    #endif

    // MARK: - Twitch EventSub (chat feed)

    /// Subscribes one Twitch EventSub WebSocket session to everything `ChatFeed` speaks. Types/versions/
    /// conditions per Twitch's EventSub subscription types reference (dev.twitch.tv/docs/eventsub/eventsub-
    /// subscription-types), current as of writing:
    ///   channel.chat.message v1  {broadcaster_user_id, user_id}           scope user:read:chat
    ///   channel.follow       v2  {broadcaster_user_id, moderator_user_id} scope moderator:read:followers
    ///   channel.subscribe    v1  {broadcaster_user_id}                    scope channel:read:subscriptions
    ///   channel.cheer        v1  {broadcaster_user_id}                    scope bits:read
    ///   channel.raid         v1  {to_broadcaster_user_id} (incoming only) no scope required
    /// A type whose scope is missing is skipped, not attempted - Twitch would 400 it silently either way, and
    /// skipping keeps `twitchMissingScopeFeatures` the one place that explains why an alert type went quiet.
    func twitchSubscribeEventSub(sessionID: String) async {
        guard !twitchUserID.isEmpty else { applog("chat", "twitch eventsub subscribe skipped: no user id yet", error: true); return }
        let transport: [String: Any] = ["method": "websocket", "session_id": sessionID]
        var subs: [(type: String, version: String, condition: [String: String])] = [
            ("channel.raid", "1", ["to_broadcaster_user_id": twitchUserID]),
        ]
        if twitchHasScopes(["user:read:chat"]) { subs.append(("channel.chat.message", "1", ["broadcaster_user_id": twitchUserID, "user_id": twitchUserID])) }
        if twitchHasScopes(["moderator:read:followers"]) { subs.append(("channel.follow", "2", ["broadcaster_user_id": twitchUserID, "moderator_user_id": twitchUserID])) }
        if twitchHasScopes(["channel:read:subscriptions"]) { subs.append(("channel.subscribe", "1", ["broadcaster_user_id": twitchUserID])) }
        if twitchHasScopes(["bits:read"]) { subs.append(("channel.cheer", "1", ["broadcaster_user_id": twitchUserID])) }
        for s in subs {
            do {
                _ = try await helix("POST", "/eventsub/subscriptions", body: ["type": s.type, "version": s.version, "condition": s.condition, "transport": transport])
            } catch {
                applog("chat", "twitch eventsub subscribe \(s.type) failed: \(error.localizedDescription)", error: true)
            }
        }
    }

    // MARK: - Twitch hands-free actions (Phase 1c)
    // One decisive tap each — nothing here needs sustained screen attention. Endpoints/scopes verified
    // against dev.twitch.tv/docs/api/reference and dev.twitch.tv/docs/authentication/scopes as of writing.

    /// POST helix/clips, scope clips:edit. Twitch creates the clip asynchronously — the id/url come back
    /// immediately but the clip itself can take a few seconds to finish processing on Twitch's side.
    /// Returns id+url on success so any caller (this view, or the live-screen button ContentView adds)
    /// can report success/failure without reaching into `status`.
    struct TwitchClip { let id: String; let url: String }
    func twitchCreateClip() async throws -> TwitchClip {
        guard !twitchUserID.isEmpty else { throw Self.err("twitch: not connected") }
        let r = try await helix("POST", "/clips", query: [.init(name: "broadcaster_id", value: twitchUserID)])
        guard let c = (r["data"] as? [[String: Any]])?.first, let id = c["id"] as? String else { throw Self.err("twitch: clip create returned no id") }
        return TwitchClip(id: id, url: "https://clips.twitch.tv/\(id)")
    }

    /// POST helix/streams/markers — body key is `user_id`, not `broadcaster_id` (Twitch's own inconsistency).
    /// Scope channel:manage:broadcast, already requested since Phase 1a, so this needs no new grant.
    func twitchCreateMarker(description: String = "") async throws {
        guard !twitchUserID.isEmpty else { throw Self.err("twitch: not connected") }
        var body: [String: Any] = ["user_id": twitchUserID]
        if !description.isEmpty { body["description"] = String(description.prefix(140)) }   // Twitch's own cap
        _ = try await helix("POST", "/streams/markers", body: body)
    }

    /// GET helix/channels/ads, scope channel:read:ads (distinct from channel:manage:ads on the snooze call
    /// below). `next_ad_at` is "" when there's nothing scheduled. Called from refreshTwitch when the scope
    /// is present; failures are logged, not surfaced to `status` — a quiet countdown beats spamming errors.
    func twitchRefreshAdSchedule() async {
        do {
            guard let a = ((try await helix("GET", "/channels/ads", query: [.init(name: "broadcaster_id", value: twitchUserID)]))["data"] as? [[String: Any]])?.first else { return }
            twitchAdSnoozeCount = a["snooze_count"] as? Int ?? 0
            if let s = a["next_ad_at"] as? String, !s.isEmpty { twitchAdNextAt = ISO8601DateFormatter().date(from: s) } else { twitchAdNextAt = nil }
        } catch { applog("api", "twitch ad schedule: \(error.localizedDescription)", error: true) }
    }

    /// POST helix/channels/ads/schedule/snooze, scope channel:manage:ads.
    func twitchSnoozeAd() async {
        do {
            _ = try await helix("POST", "/channels/ads/schedule/snooze", query: [.init(name: "broadcaster_id", value: twitchUserID)])
            status = "Ad snoozed"; await twitchRefreshAdSchedule()
        } catch { status = error.localizedDescription }
    }

    /// POST helix/channels/commercial, scope channel:edit:commercial. Twitch only accepts 30/60/90/120/150/180s.
    /// ponytail: fixed 90s, no length picker — that needs the screen. Add one if a different default matters.
    func twitchStartCommercial(seconds: Int = 90) async {
        guard !twitchUserID.isEmpty else { return }
        do {
            _ = try await helix("POST", "/channels/commercial", body: ["broadcaster_id": twitchUserID, "length": seconds])
            status = "Commercial started"
        } catch { status = error.localizedDescription }
    }

    /// PATCH helix/chat/settings, scope moderator:manage:chat_settings. `moderator_id` = the broadcaster
    /// themself, same self-as-moderator pattern as twitchSend's sender_id. ponytail: fixed 10-min
    /// follower gate / 10s slow mode, no duration tuning UI — that needs the screen mid-raid, not a tap.
    func twitchLockdownChat(on: Bool) async {
        guard !twitchUserID.isEmpty else { return }
        let body: [String: Any] = on
            ? ["follower_mode": true, "follower_mode_duration_minutes": 10, "slow_mode": true, "slow_mode_wait_seconds": 10]
            : ["follower_mode": false, "slow_mode": false]
        do {
            _ = try await helix("PATCH", "/chat/settings", query: modQuery, body: body)
            status = on ? "Chat locked down" : "Chat lockdown lifted"
        } catch { status = error.localizedDescription }
    }

    /// POST helix/chat/announcements, scope moderator:manage:announcements. ponytail: always default
    /// ("primary") color — a color picker is a screen-attention feature this app doesn't need.
    func twitchAnnounce(_ message: String) async {
        let m = message.trimmingCharacters(in: .whitespaces)
        guard !twitchUserID.isEmpty, !m.isEmpty else { return }
        do {
            _ = try await helix("POST", "/chat/announcements", query: modQuery, body: ["message": m])
            status = "Announcement sent"
        } catch { status = error.localizedDescription }
    }

    /// POST helix/raids, scope channel:manage:raids. Takes a login name (what a user would type/say),
    /// resolves it to an id via GET /users first.
    func twitchRaid(_ targetLogin: String) async {
        let login = targetLogin.trimmingCharacters(in: .whitespaces).lowercased()
        guard !twitchUserID.isEmpty, !login.isEmpty else { return }
        do {
            guard let toID = ((try await helix("GET", "/users", query: [.init(name: "login", value: login)]))["data"] as? [[String: Any]])?.first?["id"] as? String else {
                status = "Twitch: no user named \(login)"; return
            }
            _ = try await helix("POST", "/raids", query: [.init(name: "from_broadcaster_id", value: twitchUserID), .init(name: "to_broadcaster_id", value: toID)])
            status = "Raiding \(login)"
        } catch { status = error.localizedDescription }
    }

    /// DELETE helix/raids, scope channel:manage:raids.
    func twitchCancelRaid() async {
        do { _ = try await helix("DELETE", "/raids", query: [.init(name: "broadcaster_id", value: twitchUserID)]); status = "Raid cancelled" }
        catch { status = error.localizedDescription }
    }

    // Moderation: exposed as throwing methods, not the status-string pattern above, so a future per-row
    // caller (chat feed rows) can report success/failure on that one row instead of a global banner.

    /// DELETE helix/moderation/chat, scope moderator:manage:chat_messages. nil messageID clears the whole chat.
    func twitchDeleteMessage(_ messageID: String?) async throws {
        guard !twitchUserID.isEmpty else { throw Self.err("twitch: not connected") }
        var q = modQuery
        if let messageID { q.append(.init(name: "message_id", value: messageID)) }
        _ = try await helix("DELETE", "/moderation/chat", query: q)
    }

    /// POST helix/moderation/bans, scope moderator:manage:banned_users. Body is wrapped in a top-level
    /// `data` object — the one Helix moderation endpoint that does this. `duration` in seconds times out
    /// instead of banning (Twitch caps it at 1209600s / 14 days); omit for a permanent ban.
    func twitchBan(userID: String, duration: Int? = nil, reason: String = "") async throws {
        guard !twitchUserID.isEmpty else { throw Self.err("twitch: not connected") }
        var data: [String: Any] = ["user_id": userID]
        if let duration { data["duration"] = duration }
        if !reason.isEmpty { data["reason"] = reason }
        _ = try await helix("POST", "/moderation/bans", query: modQuery, body: ["data": data])
    }

    /// Timeout is just a bounded ban — same endpoint, `duration` set.
    func twitchTimeout(userID: String, seconds: Int, reason: String = "") async throws {
        try await twitchBan(userID: userID, duration: seconds, reason: reason)
    }

    /// DELETE helix/moderation/bans, scope moderator:manage:banned_users.
    func twitchUnban(userID: String) async throws {
        guard !twitchUserID.isEmpty else { throw Self.err("twitch: not connected") }
        _ = try await helix("DELETE", "/moderation/bans", query: modQuery + [.init(name: "user_id", value: userID)])
    }

    /// `broadcaster_id` + `moderator_id` query pair every moderator-scoped Helix call below needs; the
    /// broadcaster is always allowed to moderate their own channel, so moderator_id = twitchUserID.
    private var modQuery: [URLQueryItem] { [.init(name: "broadcaster_id", value: twitchUserID), .init(name: "moderator_id", value: twitchUserID)] }

    // MARK: - Restream (OAuth 2 code flow, Basic-auth token exchange, no PKCE offered)

    func connectRestream() {
        Task {
            var c = URLComponents(string: "https://api.restream.io/login")!
            c.queryItems = [
                .init(name: "response_type", value: "code"), .init(name: "client_id", value: Self.restreamID),
                .init(name: "redirect_uri", value: Self.webRedirect), .init(name: "state", value: Self.random(16)),
            ]
            guard let code = await authorize(c.url!, scheme: "metastream") else { status = "Restream login cancelled"; return }
            do {
                let json = try await Self.form("https://api.restream.io/oauth/token",
                    ["grant_type": "authorization_code", "redirect_uri": Self.webRedirect, "code": code],
                    basic: (Self.restreamID, Self.restreamSecret))
                try saveTokens(json, prefix: "restream")
                status = "Restream connected"
                await refreshRestream()
            } catch { status = "Restream token error: \(error.localizedDescription)" }
        }
    }

    private func restream(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        try await callAny(method, "https://api.restream.io/v2" + path, body: body, tokenKey: "restreamAccess") {
            let json = try await Self.form("https://api.restream.io/oauth/token",
                ["grant_type": "refresh_token", "refresh_token": self.d.string(forKey: "restreamRefresh") ?? ""],
                basic: (Self.restreamID, Self.restreamSecret))
            try self.saveTokens(json, prefix: "restream")
        }
    }

    func refreshRestream() async {
        do {
            if let p = try await restream("GET", "/user/profile") as? [String: Any] { restreamUser = p["username"] as? String ?? "" }
            // The list comes back wrapped: {"channels":[...]}; older docs show a bare array, so accept both.
            let raw = try await restream("GET", "/user/channels")
            let list = (raw as? [[String: Any]]) ?? ((raw as? [String: Any])?["channels"] as? [[String: Any]]) ?? []
            // The list omits the on/off state, so ask each channel for it. Two or three calls, once per refresh.
            var channels: [RestreamDestination] = []
            for c in list {
                guard let id = c["id"] as? Int else { continue }
                let detail = (try? await restream("GET", "/user/channels/\(id)")) as? [String: Any] ?? [:]
                let on = detail["active"] as? Bool ?? detail["enabled"] as? Bool ?? true
                channels.append(RestreamDestination(id: id, name: c["displayName"] as? String ?? "channel \(id)",
                                                url: c["channelUrl"] as? String ?? "", active: on))
            }
            restreamDestinations = channels
            if let first = restreamDestinations.first, let m = try await restream("GET", "/user/channel-meta/\(first.id)") as? [String: Any] {
                restreamTitle = m["title"] as? String ?? ""
            }
            if let k = try await restream("GET", "/user/streamKey") as? [String: Any] { restreamStreamKey = k["streamKey"] as? String ?? "" }
            if let c = try await restream("GET", "/user/webchat/url") as? [String: Any] { restreamChatURL = c["webchatUrl"] as? String ?? "" }
            status = "Restream updated"
        } catch { status = error.localizedDescription }
    }

    /// One title for every destination Restream fans out to.
    func restreamApply(title: String) async {
        do {
            for ch in restreamDestinations { _ = try await restream("PATCH", "/user/channel-meta/\(ch.id)", body: ["title": title]) }
            status = "Restream titles updated"; await refreshRestream()
        } catch { status = error.localizedDescription }
    }

    /// Enables or disables one destination. Restream documents the update under the singular path; some
    /// deployments answer on the plural one, so try both before reporting failure.
    func restreamSetActive(_ ch: RestreamDestination, _ on: Bool) async {
        func apply() { if let i = restreamDestinations.firstIndex(where: { $0.id == ch.id }) { restreamDestinations[i].active = on } }
        do {
            _ = try await restream("PATCH", "/user/channel/\(ch.id)", body: ["active": on])
            apply(); status = "\(ch.name) \(on ? "enabled" : "disabled")"
        } catch {
            do {
                _ = try await restream("PATCH", "/user/channels/\(ch.id)", body: ["active": on])
                apply(); status = "\(ch.name) \(on ? "enabled" : "disabled")"
            } catch { status = error.localizedDescription }
        }
    }

    func disconnectRestream() { forget("restream"); restreamUser = ""; restreamDestinations = []; restreamTitle = ""; restreamStreamKey = ""; restreamChatURL = "" }

    // MARK: - YouTube (Google OAuth for iOS: PKCE, no secret, bundle-id scheme redirect)

    func connectYouTube() {
        Task {
            let verifier = Self.random(64)
            var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            c.queryItems = [
                .init(name: "client_id", value: Self.youtubeID), .init(name: "redirect_uri", value: Self.googleRedirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: "https://www.googleapis.com/auth/youtube.force-ssl"),
                .init(name: "code_challenge", value: Self.s256(verifier)), .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            ]
            guard let code = await authorize(c.url!, scheme: "com.saeedkolivand.metastream") else { status = "YouTube login cancelled"; return }
            do {
                let json = try await Self.form("https://oauth2.googleapis.com/token", [
                    "client_id": Self.youtubeID, "code": code, "code_verifier": verifier,
                    "grant_type": "authorization_code", "redirect_uri": Self.googleRedirect])
                try saveTokens(json, prefix: "yt")
                status = "YouTube connected"
                await refreshYouTube()
            } catch { status = "YouTube token error: \(error.localizedDescription)" }
        }
    }

    private func yt(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        try await call(method, "https://www.googleapis.com/youtube/v3" + path, query: query, body: body, tokenKey: "ytAccess") {
            let json = try await Self.form("https://oauth2.googleapis.com/token", [
                "grant_type": "refresh_token", "client_id": Self.youtubeID, "refresh_token": self.d.string(forKey: "ytRefresh") ?? ""])
            try self.saveTokens(json, prefix: "yt")
        }
    }

    func refreshYouTube() async {
        do {
            if let ch = ((try await yt("GET", "/channels", query: [.init(name: "part", value: "snippet"), .init(name: "mine", value: "true")]))["items"] as? [[String: Any]])?.first {
                ytUser = (ch["snippet"] as? [String: Any])?["title"] as? String ?? ""
            }
            let items = (try await yt("GET", "/liveBroadcasts", query: [
                .init(name: "part", value: "id,snippet,contentDetails,status"), .init(name: "mine", value: "true"), .init(name: "maxResults", value: "10")]))["items"] as? [[String: Any]] ?? []
            let preferred = ["live", "liveStarting", "testing", "ready", "created"]
            // The broadcast YouTube Studio calls "your stream": the most alive one, else the newest.
            let pick = preferred.lazy.compactMap { s in items.first { (($0["status"] as? [String: Any])?["lifeCycleStatus"] as? String) == s } }.first ?? items.first
            if let b = pick {
                ytBroadcast = b
                ytVideoID = b["id"] as? String ?? ""
                let sn = b["snippet"] as? [String: Any] ?? [:]
                ytTitle = sn["title"] as? String ?? ""
                ytDescription = sn["description"] as? String ?? ""
                ytLiveChatID = sn["liveChatId"] as? String ?? ""
                ytPrivacy = (b["status"] as? [String: Any])?["privacyStatus"] as? String ?? "public"
                ytLatency = (b["contentDetails"] as? [String: Any])?["latencyPreference"] as? String ?? "normal"
                ytLive = ((b["status"] as? [String: Any])?["lifeCycleStatus"] as? String) == "live"
                if let v = ((try await yt("GET", "/videos", query: [.init(name: "part", value: "liveStreamingDetails"), .init(name: "id", value: ytVideoID)]))["items"] as? [[String: Any]])?.first {
                    ytViewers = Int((v["liveStreamingDetails"] as? [String: Any])?["concurrentViewers"] as? String ?? "") ?? 0
                }
            }
            if let s = ((try await yt("GET", "/liveStreams", query: [.init(name: "part", value: "cdn"), .init(name: "mine", value: "true")]))["items"] as? [[String: Any]])?.first,
               let ing = ((s["cdn"] as? [String: Any])?["ingestionInfo"] as? [String: Any]) {
                ytStreamKey = ing["streamName"] as? String ?? ""
                if let a = ing["rtmpsIngestionAddress"] as? String, !a.isEmpty { ytIngest = a }
            }
            status = "YouTube updated"
        } catch { status = error.localizedDescription }
    }

    /// `liveBroadcasts.update` REPLACES every field in each part you send — so every part below is rebuilt from
    /// the last full fetch (`ytBroadcast`, read with part=id,snippet,contentDetails,status in refreshYouTube) with
    /// only the intended field changed, never sent as a bare `{"title": …}`. Otherwise this would silently wipe
    /// the description, scheduledStartTime, and the rest of contentDetails/status.
    func ytApply(title: String, description: String, privacy: String, latency: String) async {
        guard !ytVideoID.isEmpty, let sn = ytBroadcast["snippet"] as? [String: Any] else { status = "No YouTube broadcast found. Create one in YouTube Studio first."; return }
        var st = ytBroadcast["status"] as? [String: Any] ?? [:]
        st["privacyStatus"] = privacy
        var cd = ytBroadcast["contentDetails"] as? [String: Any] ?? [:]
        cd["latencyPreference"] = latency
        let body: [String: Any] = [
            "id": ytVideoID,
            "snippet": ["title": title, "description": description, "scheduledStartTime": sn["scheduledStartTime"] ?? ""],
            "status": st, "contentDetails": cd,
        ]
        do {
            _ = try await yt("PUT", "/liveBroadcasts", query: [.init(name: "part", value: "snippet,status,contentDetails")], body: body)
            status = "YouTube updated"; await refreshYouTube()
        } catch { status = error.localizedDescription }
    }

    func ytSend(_ text: String) async {
        guard !ytLiveChatID.isEmpty else { status = "No live chat on this broadcast yet"; return }
        do {
            _ = try await yt("POST", "/liveChatMessages", query: [.init(name: "part", value: "snippet")],
                             body: ["snippet": ["liveChatId": ytLiveChatID, "type": "textMessageEvent", "textMessageDetails": ["messageText": text]]])
        } catch { status = error.localizedDescription }
    }

    func disconnectYouTube() {
        forget("yt"); ytUser = ""; ytTitle = ""; ytVideoID = ""; ytStreamKey = ""
        ytDescription = ""; ytPrivacy = "public"; ytLatency = "normal"
    }

    /// One page of `liveChat/messages` for the broadcast's live chat (same `ytLiveChatID` `ytSend` posts to).
    /// Needs no new scope - `youtube.force-ssl` already covers reading. nil when there's no live chat yet
    /// (broadcast not started/found), so the poller backs off instead of erroring.
    func ytPollLiveChat(pageToken: String?) async throws -> (items: [[String: Any]], nextPageToken: String?, pollingIntervalMillis: Int)? {
        guard !ytLiveChatID.isEmpty else { return nil }
        var query = [URLQueryItem(name: "liveChatId", value: ytLiveChatID), URLQueryItem(name: "part", value: "snippet,authorDetails")]
        if let pageToken { query.append(.init(name: "pageToken", value: pageToken)) }
        let json = try await yt("GET", "/liveChat/messages", query: query)
        return (json["items"] as? [[String: Any]] ?? [], json["nextPageToken"] as? String, json["pollingIntervalMillis"] as? Int ?? 5000)
    }

    // MARK: - plumbing

    /// Authenticated JSON-object call with one token refresh + retry on 401.
    private func call(_ method: String, _ url: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                      tokenKey: String, headers: [String: String] = [:], refresh: @escaping () async throws -> Void) async throws -> [String: Any] {
        (try await callAny(method, url, query: query, body: body, tokenKey: tokenKey, headers: headers, refresh: refresh)) as? [String: Any] ?? [:]
    }

    private func callAny(_ method: String, _ url: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                         tokenKey: String, headers: [String: String] = [:], refresh: @escaping () async throws -> Void, retried: Bool = false) async throws -> Any {
        var c = URLComponents(string: url)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(d.string(forKey: tokenKey) ?? "")", forHTTPHeaderField: "Authorization")
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        applog("api", "\(method) \(c.url!.absoluteString) -> \(code) \(redact(String(decoding: data.prefix(700), as: UTF8.self)))", error: code >= 400)
        if code == 401, !retried {
            try await refresh()
            return try await callAny(method, url, query: query, body: body, tokenKey: tokenKey, headers: headers, refresh: refresh, retried: true)
        }
        guard (200..<300).contains(code) else { throw Self.err("\(url.split(separator: "/").suffix(2).joined(separator: "/")) → HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) ?? [:])
    }

    private func saveTokens(_ json: [String: Any], prefix: String) throws {
        guard let access = json["access_token"] as? String else { throw Self.err("no access_token in \(json)") }
        d.set(access, forKey: prefix + "Access")
        if let r = json["refresh_token"] as? String { d.set(r, forKey: prefix + "Refresh") }
        // Twitch's token response carries the actually-granted scope list (it can be less than what was
        // requested, or - after a refresh - just the original grant). Persist it so a scope check never
        // has to guess from what was last *requested*.
        if let scopes = json["scope"] as? [String] {
            d.set(scopes, forKey: prefix + "Scopes")
            if prefix == "twitch" { twitchScopes = Set(scopes) }
        }
    }

    private func forget(_ prefix: String) { [prefix + "Access", prefix + "Refresh", prefix + "Scopes"].forEach { d.removeObject(forKey: $0) } }

    /// POST application/x-www-form-urlencoded → JSON object. Non-2xx throws unless allowError (device-flow polling).
    private static func form(_ url: String, _ fields: [String: String], allowError: Bool = false, basic: (String, String)? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let (u, p) = basic { req.setValue("Basic " + Data("\(u):\(p)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        applog("auth", "POST \(url) [\(fields.keys.sorted().joined(separator: ","))] -> \(code) \(code < 300 ? "ok" : redact(String(decoding: data.prefix(400), as: UTF8.self)))", error: code >= 400)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard allowError || (200..<300).contains(code) else { throw err("HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        return json
    }

    private static func s256(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    private static func err(_ s: String) -> NSError { applog("api", "error: \(s)", error: true); return NSError(domain: "Platforms", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
