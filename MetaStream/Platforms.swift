import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import os

struct StreamCategory: Identifiable, Hashable { let id: String; let name: String }
struct RestreamChannel: Identifiable, Hashable { let id: Int; let name: String; let url: String }

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
    private var twitchUserID = ""

    // Restream
    @Published var restreamUser = ""
    @Published var restreamChannels: [RestreamChannel] = []
    @Published var restreamTitle = ""
    @Published var restreamStreamKey = ""
    @Published var restreamChatURL = ""

    // YouTube
    @Published var ytUser = ""
    @Published var ytTitle = ""
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

    func kickApply(title: String, category: StreamCategory?) async {
        var body: [String: Any] = ["stream_title": title]
        if let category, let id = Int(category.id) { body["category_id"] = id }
        do { _ = try await kick("PATCH", "/public/v1/channels", body: body); status = "Kick title updated"; await refreshKick() }
        catch { status = error.localizedDescription }
    }

    func kickSend(_ text: String) async {
        do { _ = try await kick("POST", "/public/v1/chat", body: ["content": text, "type": "user", "broadcaster_user_id": kickUserID]) }
        catch { status = error.localizedDescription }
    }

    func disconnectKick() { forget("kick"); kickUser = ""; kickTitle = ""; kickCategory = nil; kickStreamKey = "" }

    // MARK: - Twitch (Device Code Grant, public client, no secret)

    func connectTwitch() {
        Task {
            do {
                let scopes = "channel:manage:broadcast channel:read:stream_key user:write:chat user:read:chat"
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
            }
            let live = ((try await helix("GET", "/streams", query: [.init(name: "user_id", value: twitchUserID)]))["data"] as? [[String: Any]])?.first
            twitchLive = live != nil
            twitchViewers = live?["viewer_count"] as? Int ?? 0
            if let k = ((try await helix("GET", "/streams/key", query: bid))["data"] as? [[String: Any]])?.first {
                twitchStreamKey = k["stream_key"] as? String ?? ""
            }
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

    func twitchApply(title: String, category: StreamCategory?) async {
        var body: [String: Any] = ["title": title]
        if let category { body["game_id"] = category.id }
        do {
            _ = try await helix("PATCH", "/channels", query: [.init(name: "broadcaster_id", value: twitchUserID)], body: body)
            status = "Twitch title updated"; await refreshTwitch()
        } catch { status = error.localizedDescription }
    }

    func twitchSend(_ text: String) async {
        do { _ = try await helix("POST", "/chat/messages", body: ["broadcaster_id": twitchUserID, "sender_id": twitchUserID, "message": text]) }
        catch { status = error.localizedDescription }
    }

    func disconnectTwitch() { forget("twitch"); twitchUser = ""; twitchTitle = ""; twitchCategory = nil; twitchStreamKey = "" }

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
            restreamChannels = list.compactMap {
                guard let id = $0["id"] as? Int else { return nil }
                return RestreamChannel(id: id, name: $0["displayName"] as? String ?? "channel \(id)",
                                       url: $0["channelUrl"] as? String ?? "")
            }
            if let first = restreamChannels.first, let m = try await restream("GET", "/user/channel-meta/\(first.id)") as? [String: Any] {
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
            for ch in restreamChannels { _ = try await restream("PATCH", "/user/channel-meta/\(ch.id)", body: ["title": title]) }
            status = "Restream titles updated"; await refreshRestream()
        } catch { status = error.localizedDescription }
    }

    func disconnectRestream() { forget("restream"); restreamUser = ""; restreamChannels = []; restreamTitle = ""; restreamStreamKey = ""; restreamChatURL = "" }

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
                ytLiveChatID = sn["liveChatId"] as? String ?? ""
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

    func ytApply(title: String) async {
        guard !ytVideoID.isEmpty, var sn = ytBroadcast["snippet"] as? [String: Any] else { status = "No YouTube broadcast found. Create one in YouTube Studio first."; return }
        sn["title"] = title
        var body: [String: Any] = ["id": ytVideoID, "snippet": ["title": title, "scheduledStartTime": sn["scheduledStartTime"] ?? "", "description": sn["description"] ?? ""]]
        if let cd = ytBroadcast["contentDetails"] { body["contentDetails"] = cd }   // PUT deletes what you omit
        do {
            _ = try await yt("PUT", "/liveBroadcasts", query: [.init(name: "part", value: "snippet,contentDetails")], body: body)
            status = "YouTube title updated"; await refreshYouTube()
        } catch { status = error.localizedDescription }
    }

    func ytSend(_ text: String) async {
        guard !ytLiveChatID.isEmpty else { status = "No live chat on this broadcast yet"; return }
        do {
            _ = try await yt("POST", "/liveChatMessages", query: [.init(name: "part", value: "snippet")],
                             body: ["snippet": ["liveChatId": ytLiveChatID, "type": "textMessageEvent", "textMessageDetails": ["messageText": text]]])
        } catch { status = error.localizedDescription }
    }

    func disconnectYouTube() { forget("yt"); ytUser = ""; ytTitle = ""; ytVideoID = ""; ytStreamKey = "" }

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
    }

    private func forget(_ prefix: String) { [prefix + "Access", prefix + "Refresh"].forEach { d.removeObject(forKey: $0) } }

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
