import Foundation

/// One chat or alert event, platform-agnostic. `origin` names the destination a viewer typed on
/// ("kick"/"twitch"/"youtube") and is only spoken when `Speaker.showOrigin` is set.
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
/// for a future chat UI. Kick, Twitch and YouTube each run independently and funnel into the same stream —
/// exactly one of these owns any given origin, so starting one never stops another. Restream chat can plug
/// into the same `events` stream later.
@MainActor
final class ChatFeed: ObservableObject {
    @Published private(set) var recent: [ChatEvent] = []   // last 100, across every origin

    let events: AsyncStream<ChatEvent>
    private let emit: AsyncStream<ChatEvent>.Continuation

    private var kickSocket: URLSessionWebSocketTask?
    private var kickTask: Task<Void, Never>?
    private var kickStopped = true

    private var twitchSocket: URLSessionWebSocketTask?
    private var twitchTask: Task<Void, Never>?
    private var twitchStopped = true

    private var ytTask: Task<Void, Never>?
    private var ytStopped = true

    // ponytail: Kick public web Pusher app key, hardcoded by Kick own web player and every community
    // Kick-chat library (kick-chat, tsuwari, ChatPlayground...). No official docs; it may rotate if Kick
    // changes web clients, in which case this feed silently stops connecting until the constant is updated.
    private static let pusherAppKey = "32cbd69e4b950bf97679"
    private static let pusherURL = URL(string: "wss://ws-us2.pusher.com/app/\(pusherAppKey)?protocol=7&client=js&version=8.4.0-rc2&flash=false")!

    init() {
        // ponytail: bufferingNewest caps memory if TTS ever falls behind a chat flood; unbounded isn't needed.
        (events, emit) = AsyncStream.makeStream(of: ChatEvent.self, bufferingPolicy: .bufferingNewest(200))
    }

    /// Stops every origin — Kick, Twitch and YouTube.
    func stop() { stopKick(); stopTwitch(); stopYouTube() }

    // MARK: - Kick (anonymous public Pusher WebSocket, no OAuth)

    /// Connects to Kick chat for `slug` (the channel name from the stream URL) and stays connected until `stopKick()`.
    func start(kickSlug: String) {
        stopKick()
        kickStopped = false
        applog("chat", "starting kick chat for \(kickSlug)")
        kickTask = Task { [weak self] in
            var backoff = 1.0
            while let self, !Task.isCancelled, !self.kickStopped {
                do {
                    let roomID = try await Self.chatroomID(slug: kickSlug)
                    try await self.connectKick(roomID: roomID)
                    backoff = 1   // clean disconnect (server closed / retryable) resets the ladder
                } catch {
                    if !self.kickStopped { applog("chat", "kick chat error: \(error.localizedDescription)", error: true) }
                }
                guard !Task.isCancelled, !self.kickStopped else { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)   // 1/2/4/8/15s
            }
        }
    }

    func stopKick() {
        kickStopped = true
        kickTask?.cancel(); kickTask = nil
        kickSocket?.cancel(with: .goingAway, reason: nil); kickSocket = nil
    }

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
        kickSocket = socket
        socket.resume()
        try await send(socket, ["event": "pusher:subscribe", "data": ["auth": "", "channel": "chatrooms.\(roomID).v2"]])
        applog("chat", "kick chat connected room=\(roomID)")
        while !Task.isCancelled, !kickStopped {
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
        yield(chatEvent)
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

    // MARK: - Twitch (EventSub WebSocket)

    /// Connects to Twitch EventSub for the currently-authorized account and stays connected until
    /// `stopTwitch()`. Identity, subscription creation and scope bookkeeping live in `Platforms` (it already
    /// owns the access token, refresh-on-401 and `twitchScopes`); this feed only speaks the WebSocket protocol.
    func startTwitch(platforms: Platforms) {
        stopTwitch()
        twitchStopped = false
        applog("chat", "starting twitch eventsub")
        twitchTask = Task { [weak self] in
            var backoff = 1.0
            while let self, !Task.isCancelled, !self.twitchStopped {
                do {
                    try await self.connectTwitch(platforms: platforms)
                    backoff = 1
                } catch {
                    if !self.twitchStopped { applog("chat", "twitch eventsub error: \(error.localizedDescription)", error: true) }
                }
                guard !Task.isCancelled, !self.twitchStopped else { return }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
            }
        }
    }

    func stopTwitch() {
        twitchStopped = true
        twitchTask?.cancel(); twitchTask = nil
        twitchSocket?.cancel(with: .goingAway, reason: nil); twitchSocket = nil
    }

    private static let twitchEventSubURL = URL(string: "wss://eventsub.wss.twitch.tv/ws")!

    /// One EventSub WebSocket lifetime: session_welcome -> subscribe -> read notifications until the socket
    /// errors, `stopTwitch()` is called, or Twitch sends session_reconnect (handled in place; Twitch migrates
    /// existing subscriptions to the new session itself, so there's nothing to resubscribe).
    private func connectTwitch(platforms: Platforms) async throws {
        var url = Self.twitchEventSubURL
        reconnect: while !Task.isCancelled, !twitchStopped {
            let socket = URLSession.shared.webSocketTask(with: url)
            twitchSocket = socket
            socket.resume()
            guard case .string(let welcomeText) = try await socket.receive(),
                  let sessionID = Self.twitchSessionID(from: welcomeText)
            else { throw NSError(domain: "ChatFeed", code: 2, userInfo: [NSLocalizedDescriptionKey: "Twitch EventSub: no session_welcome"]) }
            applog("chat", "twitch eventsub connected session=\(sessionID)")
            await platforms.twitchSubscribeEventSub(sessionID: sessionID)

            while !Task.isCancelled, !twitchStopped {
                guard case .string(let text) = try await socket.receive() else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let metadata = obj["metadata"] as? [String: Any],
                      let messageType = metadata["message_type"] as? String,
                      let payload = obj["payload"] as? [String: Any]
                else {
                    applog("chat", "twitch frame not JSON: \(text.prefix(200))", error: true)
                    continue
                }
                switch messageType {
                case "session_keepalive":
                    break
                case "session_reconnect":
                    // ponytail: swap straight to the new URL instead of running old+new sockets side by side
                    // through Twitch's ~30s grace window; worst case is a missed frame or two mid-swap.
                    if let s = (payload["session"] as? [String: Any])?["reconnect_url"] as? String, let newURL = URL(string: s) {
                        url = newURL
                    }
                    socket.cancel(with: .goingAway, reason: nil)
                    continue reconnect
                case "notification":
                    guard let subType = metadata["subscription_type"] as? String,
                          let event = payload["event"] as? [String: Any],
                          let chatEvent = Self.parseTwitchEvent(type: subType, event: event)
                    else { continue }
                    yield(chatEvent)
                default:
                    break   // revocation etc. - nothing this feed needs to act on
                }
            }
            return   // loop condition false: stopped/cancelled
        }
    }

    private static func twitchSessionID(from welcomeText: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(welcomeText.utf8)) as? [String: Any],
              (obj["metadata"] as? [String: Any])?["message_type"] as? String == "session_welcome"
        else { return nil }
        return ((obj["payload"] as? [String: Any])?["session"] as? [String: Any])?["id"] as? String
    }

    /// EventSub notification -> ChatEvent. Field names per Twitch's EventSub subscription types reference.
    private static func parseTwitchEvent(type: String, event: [String: Any]) -> ChatEvent? {
        switch type {
        case "channel.chat.message":
            guard let user = event["chatter_user_name"] as? String,
                  let text = (event["message"] as? [String: Any])?["text"] as? String
            else { return nil }
            return ChatEvent(kind: .message, user: user, text: text, origin: "twitch")
        case "channel.follow":
            guard let user = event["user_name"] as? String else { return nil }
            return ChatEvent(kind: .follow, user: user, origin: "twitch")
        case "channel.subscribe":
            guard let user = event["user_name"] as? String else { return nil }
            return ChatEvent(kind: .subscribe, user: user, origin: "twitch")
        case "channel.raid":
            guard let user = event["from_broadcaster_user_name"] as? String else { return nil }
            return ChatEvent(kind: .raid, user: user, count: event["viewers"] as? Int ?? 0, origin: "twitch")
        case "channel.cheer":
            let user = event["user_name"] as? String ?? "an anonymous cheerer"   // is_anonymous cheers null out user_name
            return ChatEvent(kind: .cheer, user: user, text: event["message"] as? String ?? "", count: event["bits"] as? Int ?? 0, origin: "twitch")
        default:
            return nil
        }
    }

    // MARK: - YouTube (liveChat/messages polling)

    /// Polls YouTube live chat until `stopYouTube()`. No push option exists for liveChat - polling at the
    /// interval the API itself hands back (`pollingIntervalMillis`) is the contract, not a shortcut around one.
    func startYouTube(platforms: Platforms) {
        stopYouTube()
        ytStopped = false
        applog("chat", "starting youtube chat poll")
        ytTask = Task { [weak self] in
            var backoff = 1.0
            var pageToken: String?
            while let self, !Task.isCancelled, !self.ytStopped {
                do {
                    guard let page = try await platforms.ytPollLiveChat(pageToken: pageToken) else {
                        try? await Task.sleep(for: .seconds(5))   // no live broadcast/chat yet
                        continue
                    }
                    pageToken = page.nextPageToken
                    for item in page.items {
                        guard let e = Self.parseYouTubeItem(item) else { continue }
                        self.yield(e)
                    }
                    backoff = 1
                    // ponytail: 2s floor only guards a pathological near-zero reply; never shorter than what YouTube asked for.
                    try? await Task.sleep(for: .milliseconds(max(page.pollingIntervalMillis, 2000)))
                } catch {
                    if !self.ytStopped { applog("chat", "youtube chat poll error: \(error.localizedDescription)", error: true) }
                    guard !Task.isCancelled, !self.ytStopped else { return }
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 15)
                }
            }
        }
    }

    func stopYouTube() {
        ytStopped = true
        ytTask?.cancel(); ytTask = nil
    }

    /// One `liveChatMessages.list` item -> ChatEvent. superChat/superSticker -> `.tip`; `amountMicros` is
    /// 1,000,000-per-currency-unit and ChatEvent wants cents, so `/ 10_000`. Anything else (membership,
    /// message deletion, etc.) is skipped rather than guessed at.
    private static func parseYouTubeItem(_ item: [String: Any]) -> ChatEvent? {
        guard let snippet = item["snippet"] as? [String: Any],
              let type = snippet["type"] as? String,
              let user = (item["authorDetails"] as? [String: Any])?["displayName"] as? String
        else { return nil }
        switch type {
        case "textMessageEvent":
            guard let text = (snippet["textMessageDetails"] as? [String: Any])?["messageText"] as? String else { return nil }
            return ChatEvent(kind: .message, user: user, text: text, origin: "youtube")
        case "superChatEvent", "superStickerEvent":
            let details = (snippet[type == "superChatEvent" ? "superChatDetails" : "superStickerDetails"] as? [String: Any]) ?? [:]
            let micros = (details["amountMicros"] as? String).flatMap(Int.init) ?? (details["amountMicros"] as? NSNumber)?.intValue ?? 0
            return ChatEvent(kind: .tip, user: user, text: details["userComment"] as? String ?? "", amountCents: micros / 10_000, origin: "youtube")
        default:
            return nil
        }
    }

    // MARK: - shared sink

    private func yield(_ e: ChatEvent) {
        recent.append(e)
        if recent.count > 100 { recent.removeFirst(recent.count - 100) }
        emit.yield(e)
    }
}

#if DEBUG
extension ChatFeed {
    /// Self-check: one realistic frame per transport, decoded into the ChatEvent Speaker expects. No framework.
    static func demo() {
        // Kick: Pusher double-JSON-encoding.
        let kickSample = #"{"event":"App\\Events\\ChatMessageEvent","channel":"chatrooms.123.v2","data":"{\"content\":\"gg [emote:12345:catJAM]\",\"sender\":{\"id\":1,\"username\":\"viewerOne\"}}"}"#
        let kickOuter = try! JSONSerialization.jsonObject(with: Data(kickSample.utf8)) as! [String: Any]
        let kickEvent = parse(event: kickOuter["event"] as! String, data: kickOuter["data"] as? String)
        assert(kickEvent?.origin == "kick")
        assert(kickEvent?.user == "viewerOne")
        assert(kickEvent?.text == "gg [emote:12345:catJAM]")
        assert(kickEvent?.kind == .message)
        assert(kickEvent?.amountCents == 0)
        assert(parse(event: "pusher:ping", data: nil) == nil)

        // Twitch: one EventSub channel.chat.message notification frame.
        let twitchFrame = #"""
        {"metadata":{"message_id":"x","message_type":"notification","message_timestamp":"2024-01-01T00:00:00Z","subscription_type":"channel.chat.message","subscription_version":"1"},"payload":{"subscription":{"id":"s1","type":"channel.chat.message","version":"1","condition":{"broadcaster_user_id":"123","user_id":"123"}},"event":{"broadcaster_user_id":"123","broadcaster_user_login":"streamer","broadcaster_user_name":"Streamer","chatter_user_id":"456","chatter_user_login":"viewer","chatter_user_name":"Viewer","message_id":"m1","message":{"text":"gg well played","fragments":[]}}}}
        """#
        let twitchObj = try! JSONSerialization.jsonObject(with: Data(twitchFrame.utf8)) as! [String: Any]
        let twitchMetadata = twitchObj["metadata"] as! [String: Any]
        let twitchPayload = twitchObj["payload"] as! [String: Any]
        let twitchEvent = parseTwitchEvent(type: twitchMetadata["subscription_type"] as! String, event: twitchPayload["event"] as! [String: Any])
        assert(twitchEvent?.kind == .message)
        assert(twitchEvent?.user == "Viewer")
        assert(twitchEvent?.text == "gg well played")
        assert(twitchEvent?.origin == "twitch")
        assert(twitchSessionID(from: #"{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"abc123"}}}"#) == "abc123")
        assert(parseTwitchEvent(type: "channel.unknown.thing", event: [:]) == nil)

        // YouTube: one liveChatMessages.list superChatEvent item.
        let ytItem: [String: Any] = [
            "snippet": ["type": "superChatEvent", "superChatDetails": ["amountMicros": "5000000", "currency": "USD", "userComment": "love the stream"]],
            "authorDetails": ["displayName": "GenerousViewer"],
        ]
        let ytEvent = parseYouTubeItem(ytItem)
        assert(ytEvent?.kind == .tip)
        assert(ytEvent?.user == "GenerousViewer")
        assert(ytEvent?.text == "love the stream")
        assert(ytEvent?.amountCents == 500)
        assert(ytEvent?.origin == "youtube")
        assert(parseYouTubeItem(["snippet": ["type": "membershipEvent"], "authorDetails": ["displayName": "x"]]) == nil)

        applog("chat", "ChatFeed.demo() passed")
    }
}
#endif
