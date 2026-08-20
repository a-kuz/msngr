import XCTest
@testable import MsngrCore

/// The rule the socket's watchdog runs on. Everything it has to catch is a
/// silence: a stalled stream calls nothing back, so the verdict comes from the
/// clock alone.
final class WSFreshnessTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAnUpgradeThatBringsNothingIsDead() {
        let verdict = WSFreshness.decide(now: t0.addingTimeInterval(WSFreshness.handshake + 1),
                                         connected: false, openedAt: t0,
                                         lastFrameAt: nil, pingSentAt: nil)
        XCTAssertEqual(verdict, .dead)
    }

    func testAnUpgradeStillYoungIsWaitedFor() {
        let verdict = WSFreshness.decide(now: t0.addingTimeInterval(2),
                                         connected: false, openedAt: t0,
                                         lastFrameAt: nil, pingSentAt: nil)
        XCTAssertEqual(verdict, .wait)
    }

    func testQuietForLongEnoughEarnsAPing() {
        let verdict = WSFreshness.decide(now: t0.addingTimeInterval(WSFreshness.quiet + 1),
                                         connected: true, openedAt: t0,
                                         lastFrameAt: t0, pingSentAt: nil)
        XCTAssertEqual(verdict, .ping)
    }

    func testATalkingSocketIsLeftAlone() {
        let now = t0.addingTimeInterval(60)
        let verdict = WSFreshness.decide(now: now, connected: true, openedAt: t0,
                                         lastFrameAt: now.addingTimeInterval(-1),
                                         pingSentAt: nil)
        XCTAssertEqual(verdict, .wait)
    }

    func testAPingWithNoAnswerKillsTheSocket() {
        let now = t0.addingTimeInterval(30)
        let verdict = WSFreshness.decide(now: now, connected: true, openedAt: t0,
                                         lastFrameAt: t0,
                                         pingSentAt: now.addingTimeInterval(-WSFreshness.pong - 1))
        XCTAssertEqual(verdict, .dead)
    }

    func testAPingStillInFlightIsWaitedFor() {
        let now = t0.addingTimeInterval(30)
        let verdict = WSFreshness.decide(now: now, connected: true, openedAt: t0,
                                         lastFrameAt: t0,
                                         pingSentAt: now.addingTimeInterval(-1))
        XCTAssertEqual(verdict, .wait)
    }

    /// A socket that connected and then said nothing has no last frame of its
    /// own: the upgrade is what the quiet is counted from.
    func testSilenceSinceTheUpgradeCountsToo() {
        let verdict = WSFreshness.decide(now: t0.addingTimeInterval(WSFreshness.quiet + 1),
                                         connected: true, openedAt: t0,
                                         lastFrameAt: nil, pingSentAt: nil)
        XCTAssertEqual(verdict, .ping)
    }

    /// The pong deadline is shorter than the quiet one, so a dead socket is
    /// noticed inside a few seconds rather than a full cycle.
    func testDeathIsNoticedInsideOneQuietPeriod() {
        XCTAssertLessThan(WSFreshness.pong, WSFreshness.quiet)
        XCTAssertLessThan(WSFreshness.quiet + WSFreshness.pong, 20)
    }
}
