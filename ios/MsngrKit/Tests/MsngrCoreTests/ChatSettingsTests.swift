import XCTest
@testable import MsngrCore

/// Timed mute and the permissions a chat member has.
final class ChatSettingsTests: XCTestCase {
    private let now: Double = 1_000_000

    // MARK: - Mute expiry

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

    /// An option's deadline holds right up to its end and not past it.
    func testOptionMuteLifecycle() {
        for option in MuteOption.allCases {
            let until = option.until(from: now)
            XCTAssertTrue(MuteState.isMuted(muted: true, mutedUntil: until, now: now + 1),
                          "\(option) should mute straight after it is switched on")
            let later = now + (option.seconds ?? 0) + 1
            XCTAssertEqual(MuteState.isMuted(muted: true, mutedUntil: until, now: later),
                           option == .forever,
                           "\(option) past its deadline")
        }
    }

    func testUntilLabelOnlyForTimedMute() {
        XCTAssertNil(MuteState.untilLabel(muted: true, mutedUntil: nil, now: now))
        XCTAssertNil(MuteState.untilLabel(muted: false, mutedUntil: now + 60, now: now))
        XCTAssertNil(MuteState.untilLabel(muted: true, mutedUntil: now - 60, now: now))
        XCTAssertNotNil(MuteState.untilLabel(muted: true, mutedUntil: now + 60, now: now))
    }

    // MARK: - Permissions by role

    func testGroupSettingsOnlyForAdmin() {
        XCTAssertTrue(ChatPermissions.canEditSettings(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canEditSettings(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canEditSettings(kind: .group, role: nil))
    }

    func testMentionAllOnlyForAGroupAdmin() {
        XCTAssertTrue(ChatPermissions.canMentionAll(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canMentionAll(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canMentionAll(kind: .group, role: nil))
        XCTAssertFalse(ChatPermissions.canMentionAll(kind: .direct, role: "admin"))
    }

    func testDirectSettingsForAnyMember() {
        XCTAssertTrue(ChatPermissions.canEditSettings(kind: .direct, role: "member"))
        XCTAssertFalse(ChatPermissions.canEditSettings(kind: .direct, role: nil))
    }

    func testMemberManagement() {
        XCTAssertTrue(ChatPermissions.canRemoveMembers(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canRemoveMembers(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canRemoveMembers(kind: .direct, role: "admin"))

        XCTAssertTrue(ChatPermissions.canInvite(kind: .group, role: "admin", invitePolicy: "all"))
        XCTAssertTrue(ChatPermissions.canInvite(kind: .group, role: "member", invitePolicy: "all"))
        XCTAssertFalse(ChatPermissions.canInvite(kind: .direct, role: "admin", invitePolicy: "all"))
    }

    func testInvitingLockedToAdmins() {
        XCTAssertTrue(ChatPermissions.canInvite(kind: .group, role: "admin", invitePolicy: "admins"))
        XCTAssertFalse(ChatPermissions.canInvite(kind: .group, role: "member", invitePolicy: "admins"))
        XCTAssertFalse(ChatPermissions.canInvite(kind: .group, role: nil, invitePolicy: "all"))
    }

    func testWritingUnderTheSendPolicy() {
        XCTAssertTrue(ChatPermissions.canSend(kind: .group, role: "member", sendPolicy: "all"))
        XCTAssertFalse(ChatPermissions.canSend(kind: .group, role: "member", sendPolicy: "admins"))
        XCTAssertTrue(ChatPermissions.canSend(kind: .group, role: "admin", sendPolicy: "admins"))
        // a direct chat has no roles to check
        XCTAssertTrue(ChatPermissions.canSend(kind: .direct, role: nil, sendPolicy: "admins"))
    }

    func testAdminsAndLeave() {
        XCTAssertTrue(ChatPermissions.canManageAdmins(kind: .group, role: "admin"))
        XCTAssertFalse(ChatPermissions.canManageAdmins(kind: .group, role: "member"))
        XCTAssertTrue(ChatPermissions.canLeave(kind: .group, role: "member"))
        XCTAssertFalse(ChatPermissions.canLeave(kind: .group, role: nil))
        XCTAssertFalse(ChatPermissions.canLeave(kind: .direct, role: "member"))
    }
}
