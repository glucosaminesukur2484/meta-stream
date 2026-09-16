import XCTest
@testable import MetaStream

/// The `demo()` self-checks scattered through the app were `#if DEBUG` and CI only ever built
/// Release, so none of them had been compiled, let alone run. This target exists purely to run
/// them, so an assert that starts failing is a red build rather than dead code that looks like
/// coverage. Each demo() asserts internally; reaching the end without trapping is the pass.
@MainActor
final class SelfCheckTests: XCTestCase {
    func testSpeakerSanitisingAndQueueBounds() { Speaker.demo() }
    func testChatFeedFrameDecoding() { ChatFeed.demo() }
    func testStreamerBitrateSteps() { Streamer.demo() }
}
