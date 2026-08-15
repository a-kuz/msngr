import XCTest
@testable import MsngrCore

/// Mute со сроком и права участника чата.
final class ChatSettingsTests: XCTestCase {
    private let now: Double = 1_000_000

    // MARK: - Истечение mute

    func testMuteForeverNeverExpires() {
        XCTAssertTrue(MuteState.isMuted(muted: true, mutedUntil: nil, now: now))
        XCTAssertFalse(MuteState.isExpired(muted: true, mutedUntil: nil, now: now))
    }

    func testMuteActiveUntilDeadline() {
        let until = now + 3600
        XCTAssertTrue(MuteState.isMuted(muted: true, mutedUntil: until, now: now))
        XCTAssertTrue(MuteState.isMuted(muted: true, mutedUntil: until, now: until - 1))
        XCTAssertFalse(MuteState.isMuted(muted: true, mutedUntil: until, now: until))
        XCTAssertFalse(MuteState.isMuted(muted: true, mutedUntil: until, now: until + 1))
    }

    func testExpiredMuteIsSweepable() {
        XCTAssertFalse(MuteState.isExpired(muted: true, mutedUntil: now + 1, now: now))
        XCTAssertTrue(MuteState.isExpired(muted: true, mutedUntil: now, now: now))
        XCTAssertTrue(MuteState.isExpired(muted: true, mutedUntil: now - 1, now: now))
    }

    func testNotMutedIgnoresDeadline() {
        XCTAssertFalse(MuteState.isMuted(muted: false, mutedUntil: now + 3600, now: now))
        XCTAssertFalse(MuteState.isExpired(muted: false, mutedUntil: now - 3600, now: now))
    }

    func testOptionDeadlines() {
        XCTAssertEqual(MuteOption.hour.until(from: now), now + 3600)
        XCTAssertEqual(MuteOption.eightHours.until(from: now), now + 8 * 3600)
        XCTAssertEqual(MuteOption.week.until(from: now), now + 7 * 24 * 3600)
        XCTAssertNil(MuteOption.forever.until(from: now))
    }

    /// Срок из опции жив ровно до своего конца.
    func testOptionMuteLifecycle() {
        for option in MuteOption.allCases {
            let until = option.until(from: now)
            XCTAssertTrue(MuteState.isMuted(muted: true, mutedUntil: until, now: now + 1),
                          "\(option) должен молчать сразу после включения")
            let later = now + (option.seconds ?? 0) + 1
            XCTAssertEqual(MuteState.isMuted(muted: true, mutedUntil: until, now: later),
                           option == .forever,
                           "\(option) после срока")
        }
    }

    func testUntilLabelOnlyForTimedMute() {
        XCTAssertNil(MuteState.untilLabel(muted: true, mutedUntil: nil, now: now))
        XCTAssertNil(MuteState.untilLabel(muted: false, mutedUntil: now + 60, now: now))
        XCTAssertNil(MuteState.untilLabel(muted: true, mutedUntil: now - 60, now: now))
        XCTAssertNotNil(MuteState.untilLabel(muted: true, mutedUntil: now + 60, now: now))
    }

    // MARK: - Права по роли

    func testGroupSettingsOnlyForAdmin() {
        XCTAssertTrue(ChatPermissions.canEditSettings(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canEditSettings(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canEditSettings(kind: .group, role: nil))
    }

    func testDirectSettingsForAnyMember() {
        XCTAssertTrue(ChatPermissions.canEditSettings(kind: .direct, role: "member"))
        XCTAssertFalse(ChatPermissions.canEditSettings(kind: .direct, role: nil))
    }

    func testMemberManagement() {
        XCTAssertTrue(ChatPermissions.canRemoveMembers(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canRemoveMembers(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canRemoveMembers(kind: .direct, role: "admin"))

        XCTAssertTrue(ChatPermissions.canAddMembers(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canAddMembers(kind: .group, role: "member"))
        XCTAssertTrue(ChatPermissions.canAddMembers(kind: .group, role: "member", onlySelf: true))
        XCTAssertFalse(ChatPermissions.canAddMembers(kind: .direct, role: "admin"))
    }

    func testAdminsAndLeave() {
        XCTAssertTrue(ChatPermissions.canManageAdmins(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canManageAdmins(kind: .group, role: "member"))
        XCTAssertTrue(ChatPermissions.canLeave(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canLeave(kind: .group, role: nil))
        XCTAssertFalse(ChatPermissions.canLeave(kind: .direct, role: "member"))
    }
}
