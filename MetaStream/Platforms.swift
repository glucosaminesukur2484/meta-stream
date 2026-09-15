import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

struct StreamCategory: Identifiable, Hashable { let id: String; let name: String }

/// Kick + Twitch accounts: login, channel info (title/category/viewers), chat send, stream key.
/// ponytail: tokens live in UserDefaults; move to Keychain if the phone is shared.
@MainActor
final class Platforms: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var status = ""

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

    private var authSession: ASWebAuthenticationSession?
    private let d = UserDefaults.standard
    private static let info = Bundle.main.infoDictionary ?? [:]
    private static let kickID = info["KickClientID"] as? String ?? ""
    private static let kickSecret = info["KickClientSecret"] as? String ?? ""
    private static let twitchID = info["TwitchClientID"] as? String ?? ""
    static let kickRedirect = "https://metastream.iamsaeed.dev/oauth.html"   // GitHub Pages (docs/) behind a custom domain
    static let kickIngest = "rtmps://fa723fc1b171.global-contribute.live-video.net:443/app/"
    static let twitchIngest = "rtmps://live.twitch.tv:443/app/"

    var kickConnected: Bool { d.string(forKey: "kickAccess") != nil }
    var twitchConnected: Bool { d.string(forKey: "twitchAccess") != nil }

    override init() {
        super.init()
        if kickConnected { Task { await refreshKick() } }
        if twitchConnected { Task { await refreshTwitch() } }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    // MARK: - Kick login (OAuth 2.1 + PKCE, https redirect page → metastream:// scheme)

    func connectKick() {
        let verifier = Self.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://id.kick.com/oauth/authorize")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.kickID),
            .init(name: "redirect_uri", value: Self.kickRedirect),
            .init(name: "scope", value: "user:read channel:read channel:write chat:write streamkey:read"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: Self.random(16)),
        ]
        status = "Opening Kick login…"
        let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "metastream") { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                guard let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.status = "Kick login cancelled: \(error?.localizedDescription ?? "no code")"
                    return
                }
                await self.exchangeKick(code: code, verifier: verifier)
            }
        }
        s.presentationContextProvider = self
        authSession = s
        s.start()
    }

    private func exchangeKick(code: String, verifier: String) async {
        do {
            let json = try await Self.form("https://id.kick.com/oauth/token", [
                "grant_type": "authorization_code", "client_id": Self.kickID, "client_secret": Self.kickSecret,
                "redirect_uri": Self.kickRedirect, "code_verifier": verifier, "code": code])
            try saveTokens(json, prefix: "kick")
            status = "Kick connected"
            await refreshKick()
        } catch { status = "Kick token error: \(error.localizedDescription)" }
    }

    private func refreshKickToken() async throws {
        let json = try await Self.form("https://id.kick.com/oauth/token", [
            "grant_type": "refresh_token", "client_id": Self.kickID, "client_secret": Self.kickSecret,
            "refresh_token": d.string(forKey: "kickRefresh") ?? ""])
        try saveTokens(json, prefix: "kick")
    }

    private func kick(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: "https://api.kick.com" + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(d.string(forKey: "kickAccess") ?? "")", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {                                  // ponytail: one refresh, one retry
            try await refreshKickToken()
            return try await kick(method, path, query: query, body: body)
        }
        guard (200..<300).contains(code) else { throw Self.err("Kick \(path) → HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
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

    func disconnectKick() {
        ["kickAccess", "kickRefresh"].forEach { d.removeObject(forKey: $0) }
        kickUser = ""; kickTitle = ""; kickCategory = nil; kickStreamKey = ""
    }

    // MARK: - Twitch login (Device Code Grant, public client, no secret)

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

    private func refreshTwitchToken() async throws {
        let json = try await Self.form("https://id.twitch.tv/oauth2/token", [
            "grant_type": "refresh_token", "client_id": Self.twitchID, "refresh_token": d.string(forKey: "twitchRefresh") ?? ""])
        try saveTokens(json, prefix: "twitch")
    }

    private func helix(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var c = URLComponents(string: "https://api.twitch.tv/helix" + path)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(d.string(forKey: "twitchAccess") ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue(Self.twitchID, forHTTPHeaderField: "Client-Id")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 {
            try await refreshTwitchToken()
            return try await helix(method, path, query: query, body: body)
        }
        guard (200..<300).contains(code) else { throw Self.err("Twitch \(path) → HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
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

    func disconnectTwitch() {
        ["twitchAccess", "twitchRefresh"].forEach { d.removeObject(forKey: $0) }
        twitchUser = ""; twitchTitle = ""; twitchCategory = nil; twitchStreamKey = ""
    }

    // MARK: - helpers

    private func saveTokens(_ json: [String: Any], prefix: String) throws {
        guard let access = json["access_token"] as? String else { throw Self.err("no access_token in \(json)") }
        d.set(access, forKey: prefix + "Access")
        if let r = json["refresh_token"] as? String { d.set(r, forKey: prefix + "Refresh") }
    }

    /// POST application/x-www-form-urlencoded, returns JSON object. Non-2xx throws unless allowError (device-flow polling).
    private static func form(_ url: String, _ fields: [String: String], allowError: Bool = false) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard allowError || (200..<300).contains(code) else { throw err("HTTP \(code): \(String(data: data, encoding: .utf8) ?? "")") }
        return json
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Platforms", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
