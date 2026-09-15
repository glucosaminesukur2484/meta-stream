import Foundation

/// One chat or alert event, platform-agnostic. `origin` names the destination a viewer typed on
/// ("kick" for now, others later) and is only spoken when `Speaker.showOrigin` is set.
/// Two numeric fields cover everything: `amountCents` is money (tips), `count` is countable
/// things (raid viewers, cheered bits). ponytail: cents as Int, never Double — currency in
/// floating point is a rounding bug waiting to happen.
struct ChatEvent: Sendable {
    enum Kind: Equatable { case message, tip, cheer, follow, subscribe, raid }
    let kind: Kind
    let user: String
    var text: String = ""
    var amountCents: Int = 0
    var count: Int = 0
    var origin: String = ""
}

/// Live chat as one AsyncStream<ChatEvent> (text-to-speech drives off it) plus a recent-messages buffer
/// for a future chat UI. Kick only for now — anonymous public Pusher WebSocket, no OAuth, no scopes.
/// Twitch/YouTube/Restream chat can plug into the same `events` stream later; not built until Kick ships.
@MainActor
final class ChatFeed: ObservableObject {
    @Published private(set) var recent: [ChatEvent] = []   // last 100

    let events: AsyncStream<ChatEvent>
    private let emit: AsyncStream<ChatEvent>.Continuation

    private var socket: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var stopped = true

    // ponytail: Kick public web Pusher app key, hardcoded by Kick own web player and every community
    // Kick-chat library (kick-chat, tsuwari, ChatPlayground...). No official docs; it may rotate if Kick
    // changes web clients, in which case this feed silently stops connecting until the constant is updated.
    private static let pusherAppKey = "32cbd69e4b950bf97679"
    private static let pusherURL = URL(string: "wss://ws-us2.pusher.com/app/\(pusherAppKey)?protocol=7&client=js&version=8.4.0-rc2&flash=false")!

    init() {
        // ponytail: bufferingNewest caps memory if TTS ever falls behind a chat flood; unbounded isn't needed.
        (events, emit) = AsyncStream.makeStream(of: ChatEvent.self, bufferingPolicy: .bufferingNewest(200))
    }

    /// Connects to Kick chat for `slug` (the channel name from the stream URL) and stays connected until `stop()`.
    func start(kickSlug: String) {
        stop()
        stopped = false
        applog("chat", "starting kick chat for \(kickSlug)")
        runTask = Task { [weak self] in
            var backoff = 1.0
            while let self, !Task.isCancelled, !self.stopped {
                do {
                    let roomID = try await Self.chatroomID(slug: kickSlug)
                    try await self.connectKick(roomID: roomID)
                    backoff = 1   // clean disconnect (server closed / retryable) resets the ladder
                } catch {
                    if !self.stopped { applog("chat", "kick chat error: \(error.localizedDescription)", error: true) }
                }
                guard !Task.isCancelled, !self.stopped else { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)   // 1/2/4/8/15s
            }
        }
    }

    func stop() {
        stopped = true
        runTask?.cancel(); runTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    // MARK: - Kick

    /// GET kick.com/api/v2/channels/{slug} -> chatroom.id. Kick sometimes answers non-browser clients with a
    /// Cloudflare challenge page instead of JSON; a normal browser User-Agent avoids most of that.
    private static func chatroomID(slug: String) async throws -> Int {
        var req = URLRequest(url: URL(string: "https://kick.com/api/v2/channels/\(slug)")!)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chatroom = json["chatroom"] as? [String: Any],
              let id = chatroom["id"] as? Int
        else {
            applog("chat", "kick channel lookup failed slug=\(slug) code=\(code) body=\(String(decoding: data.prefix(200), as: UTF8.self))", error: true)
            throw NSError(domain: "ChatFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kick channel lookup failed for \(slug) (HTTP \(code))"])
        }
        return id
    }

    private func connectKick(roomID: Int) async throws {
        let socket = URLSession.shared.webSocketTask(with: Self.pusherURL)
        self.socket = socket
        socket.resume()
        try await send(socket, ["event": "pusher:subscribe", "data": ["auth": "", "channel": "chatrooms.\(roomID).v2"]])
        applog("chat", "kick chat connected room=\(roomID)")
        while !Task.isCancelled, !stopped {
            guard case .string(let text) = try await socket.receive() else { continue }
            try await handle(frame: text, socket: socket)
        }
    }

    private func send(_ socket: URLSessionWebSocketTask, _ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// One Pusher frame in. `pusher:ping` gets an immediate pong; a chat message becomes a ChatEvent.
    /// Malformed or uninteresting frames are ignored, not thrown - one bad frame should not kill the connection.
    private func handle(frame text: String, socket: URLSessionWebSocketTask) async throws {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = outer["event"] as? String else {
            applog("chat", "kick frame not JSON: \(text.prefix(200))", error: true)
            return
        }
        if event == "pusher:ping" { try await socket.send(.string(#"{"event":"pusher:pong"}"#)); return }
        guard let chatEvent = Self.parse(event: event, data: outer["data"] as? String) else { return }
        recent.append(chatEvent)
        if recent.count > 100 { recent.removeFirst(recent.count - 100) }
        emit.yield(chatEvent)
    }

    /// Pusher double-encodes chat messages: `data` is itself a JSON string, decoded again for the real payload.
    /// Kick emotes arrive inline in `content` as `[emote:12345:catJAM]` - left as-is; a Speaker strips them
    /// for speech and a future chat UI renders them.
    private static func parse(event: String, data: String?) -> ChatEvent? {
        guard event == "App\\Events\\ChatMessageEvent", let data,
              let inner = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              let content = inner["content"] as? String,
              let sender = inner["sender"] as? [String: Any],
              let username = sender["username"] as? String
        else { return nil }
        return ChatEvent(kind: .message, user: username, text: content, origin: "kick")
    }
}

#if DEBUG
extension ChatFeed {
    /// Self-check: Pusher double-JSON-encoding decoded into a ChatEvent, from one realistic sample frame.
    static func demo() {
        let sample = #"{"event":"App\\Events\\ChatMessageEvent","channel":"chatrooms.123.v2","data":"{\"content\":\"gg [emote:12345:catJAM]\",\"sender\":{\"id\":1,\"username\":\"viewerOne\"}}"}"#
        let outer = try! JSONSerialization.jsonObject(with: Data(sample.utf8)) as! [String: Any]
        let event = parse(event: outer["event"] as! String, data: outer["data"] as? String)
        assert(event?.origin == "kick")
        assert(event?.user == "viewerOne")
        assert(event?.text == "gg [emote:12345:catJAM]")
        assert(event?.kind == .message)
        assert(event?.amountCents == 0)
        assert(parse(event: "pusher:ping", data: nil) == nil)
        applog("chat", "ChatFeed.demo() passed")
    }
}
#endif
