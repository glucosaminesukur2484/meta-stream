import Foundation
import SwiftUI
import AVFoundation

// ChatEvent lives in ChatFeed.swift — the producer owns the type.

/// Text-to-speech with three priority lanes: System (interrupts, never dropped, never muted), Alert (tips/follows/
/// subs/raids/ad-breaks, queued) and Chat (chat messages, queued and rate-limited). One AVSpeechSynthesizer utterance
/// plays at a time; `speakNext()` picks the highest-priority non-empty lane each time it's free to speak.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // Settings the view can bind to (voice/rate picker, per-kind toggles, min-tip slider).
    @AppStorage("ttsVoiceID") var voiceID = ""            // AVSpeechSynthesisVoice identifier; empty = system default
    @AppStorage("ttsRate") var rate: Double = 0.5          // AVSpeechUtteranceDefaultSpeechRate
    @AppStorage("ttsMinTipCents") var minTipCents = 0
    @AppStorage("ttsMessagesOn") var messagesOn = true
    @AppStorage("ttsTipsOn") var tipsOn = true
    @AppStorage("ttsFollowsOn") var followsOn = true
    @AppStorage("ttsSubsOn") var subsOn = true
    @AppStorage("ttsRaidsOn") var raidsOn = true

    @Published var muted = false
    // ponytail: intentional and not to be "simplified" away — mute only silences Alert/Chat below.
    // A streamer who muted TTS because chat got noisy still needs to hear their stream died (System lane).
    var showOrigin = false   // caller sets this when more than one chat origin is live, e.g. "on Kick, Bob says …"

    private let synth = AVSpeechSynthesizer()
    private var systemQueue: [String] = []   // unbounded: System is never dropped
    private var alertQueue: [String] = []
    private var chatQueue: [String] = []
    private var chatSpokenAt: [Date] = []    // sliding 60s window for the chat rate limit
    private let laneCap = 5
    private let chatPerMinuteCap = 20
    private var repeating: [String: Task<Void, Never>] = [:]

    override init() {
        super.init()
        synth.delegate = self
        // ponytail: usesApplicationAudioSession=false gives TTS its own ambient/mixed session instead of this
        // file touching AVAudioSession category (Streamer.swift already owns that for the RTMP mic pipeline).
        // Known ceiling: with the glasses HFP mic selected, the open-ear speaker can bleed back into the mic —
        // the Settings UI should warn about that, not code around it.
        synth.usesApplicationAudioSession = false
        // ponytail: 5 s poll so a chat message waiting on the per-minute cap gets spoken once it frees up,
        // instead of scheduling a wake timer per queued message.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.speakNext()
            }
        }
    }

    // MARK: System lane

    func speakSystem(_ text: String) {
        systemQueue.append(text)
        if synth.isSpeaking { synth.stopSpeaking(at: .word) } else { speakNext() }
    }

    /// Speaks `text` now, then again at 30 s / 60 s / 2 min while the condition persists (call `stopRepeating`
    /// once it clears). Re-calling with the same `id` while already repeating is a no-op.
    func startRepeating(id: String, text: String) {
        guard repeating[id] == nil else { return }
        speakSystem(text)
        repeating[id] = Task { [weak self] in
            for delay in [30, 60, 120] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.speakSystem(text)
            }
        }
    }

    /// Stops the repeat schedule for `id`; pass `recovered` to announce recovery once, on the System lane.
    func stopRepeating(id: String, recovered: String? = nil) {
        repeating[id]?.cancel()
        repeating[id] = nil
        if let recovered { speakSystem(recovered) }
    }

    // MARK: Alert lane

    /// Generic alert with no template, e.g. "ad break in 90 seconds".
    func speakAlert(_ text: String) {
        enqueueAlert(String(text.prefix(200)))
    }

    // MARK: Chat lane + templated alerts (tip/follow/subscribe/raid)

    func speak(_ event: ChatEvent) {
        guard var text = sentence(for: event) else { return }   // mute is enforced in enqueueAlert/enqueueChat
        if showOrigin, !event.origin.isEmpty { text = "on \(event.origin), " + text }
        switch event.kind {
        case .message: enqueueChat(text)
        default: enqueueAlert(text)
        }
    }

    private func sentence(for e: ChatEvent) -> String? {
        switch e.kind {
        case .message:
            guard messagesOn else { return nil }
            let text = Self.sanitize(e.text)
            guard !text.isEmpty else { return nil }
            return "\(e.user) says \(text)"
        case .tip:
            guard tipsOn, e.amountCents >= minTipCents else { return nil }
            let amount = Self.spokenAmount(cents: e.amountCents)
            let note = Self.sanitize(e.text)
            return note.isEmpty ? "\(e.user) tipped \(amount)" : "\(e.user) tipped \(amount): \(note)"
        case .follow:
            return followsOn ? "\(e.user) followed" : nil
        case .subscribe:
            return subsOn ? "\(e.user) subscribed" : nil
        case .cheer:
            guard tipsOn else { return nil }   // bits are money; same gate as tips
            let note = Self.sanitize(e.text)
            return note.isEmpty ? "\(e.user) cheered \(e.count) bits" : "\(e.user) cheered \(e.count) bits: \(note)"
        case .raid:
            return raidsOn ? "\(e.user) raided with \(e.count) viewers" : nil
        }
    }

    private func enqueueAlert(_ text: String) {
        guard !muted else { return }
        pushBounded(text, into: &alertQueue)
        if !synth.isSpeaking { speakNext() }
    }

    private func enqueueChat(_ text: String) {
        guard !muted else { return }
        pushBounded(text, into: &chatQueue)
        if !synth.isSpeaking { speakNext() }
    }

    private func pushBounded(_ text: String, into queue: inout [String]) {
        queue.append(text)
        if queue.count > laneCap { queue.removeFirst() }   // drop OLDEST: freshness beats completeness
    }

    // MARK: queue engine

    private func speakNext() {
        guard !synth.isSpeaking else { return }
        if !systemQueue.isEmpty {
            speakNow(systemQueue.removeFirst())
        } else if !muted, !alertQueue.isEmpty {
            speakNow(alertQueue.removeFirst())
        } else if !muted, !chatQueue.isEmpty, chatUnderRateLimit() {
            chatSpokenAt.append(Date())
            speakNow(chatQueue.removeFirst())
        }
    }

    private func chatUnderRateLimit() -> Bool {
        let cutoff = Date().addingTimeInterval(-60)
        chatSpokenAt.removeAll { $0 < cutoff }
        return chatSpokenAt.count < chatPerMinuteCap
    }

    private func speakNow(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        if !voiceID.isEmpty { u.voice = AVSpeechSynthesisVoice(identifier: voiceID) }
        u.rate = Float(rate)
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speakNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speakNext() }
    }

    // MARK: text shaping

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://\S+|\bwww\.\S+"#)
    private static let bracketEmote = try! NSRegularExpression(pattern: #"\[emote:\d+:[^\]]+\]"#)   // Kick: [emote:12345:catJAM]
    private static let colonEmote = try! NSRegularExpression(pattern: #":[A-Za-z0-9_]+:"#)           // e.g. :LUL:
    private static let mention = try! NSRegularExpression(pattern: #"@(\w+)"#)                       // @Bob -> Bob

    /// Strips URLs/emotes/@ (keeping the name), collapses whitespace, caps length so one troll can't hog the queue.
    private static func sanitize(_ raw: String, maxLength: Int = 200) -> String {
        var s = raw
        for re in [urlPattern, bracketEmote, colonEmote] {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = mention.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return s.count > maxLength ? String(s.prefix(maxLength)) : s
    }

    /// Spells whole-dollar amounts ("five dollars"); anything with cents stays a plain number ("12.50 dollars").
    private static func spokenAmount(cents: Int) -> String {
        guard cents > 0 else { return "money" }
        let dollars = cents / 100
        guard cents % 100 == 0 else { return String(format: "%.2f dollars", Double(cents) / 100) }
        let f = NumberFormatter(); f.numberStyle = .spellOut
        let words = f.string(from: NSNumber(value: dollars)) ?? String(dollars)
        return "\(words) dollar\(dollars == 1 ? "" : "s")"
    }
}

#if DEBUG
extension Speaker {
    /// Self-check for the two non-trivial bits: text sanitising and drop-oldest bounding. No framework, no fixtures.
    static func demo() {
        let s = sanitize("hey @Bob check https://x.co/y :LUL: [emote:12345:catJAM]   nice   clip")
        assert(s == "hey Bob check nice clip", "sanitize: \(s)")
        let capped = sanitize(String(repeating: "a", count: 250))
        assert(capped.count == 200, "cap: \(capped.count)")
        assert(spokenAmount(cents: 500) == "five dollars", "amount: \(spokenAmount(cents: 500))")
        var q: [Int] = []
        for i in 1...7 { q.append(i); if q.count > 5 { q.removeFirst() } }   // mirrors pushBounded's drop-oldest
        assert(q == [3, 4, 5, 6, 7], "drop-oldest: \(q)")
        print("Speaker.demo() ok")
    }
}
#endif
