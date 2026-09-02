import XCTest
@testable import Msngr

/// The note rows (the date capsule, a system line, the unread band) sit shifted
/// toward the newer message: that message is the first of its series and
/// brings its own gap on that side.
final class DateSeparatorSpacingTests: XCTestCase {

    private func capsule(in cell: DateSeparatorCell) -> UIView? {
        cell.contentView.subviews.first { $0 is DateCapsuleView }
    }

    func testTheCapsuleLeansTowardTheNewerMessage() {
        let cell = DateSeparatorCell(frame: CGRect(x: 0, y: 0, width: 390, height: 34))
        cell.configure("Сегодня")
        let capsule = capsule(in: cell)
        XCTAssertNotNil(capsule)
        XCTAssertEqual(capsule?.center.y ?? 0,
                       cell.contentView.bounds.midY + FeedNote.gapShift,
                       accuracy: 0.5)
        XCTAssertEqual(capsule?.center.x ?? 0, cell.contentView.bounds.midX, accuracy: 0.5)
    }

    func testTheShiftEvensOutTheSeriesGap() {
        // the row's air plus the shift on one side, the air minus the shift
        // plus the neighbour's normalGap on the other: both come out equal
        XCTAssertEqual(FeedNote.gapShift * 2, BubbleLayout.normalGap)
    }

    func testTheSystemLineLeansTheSameWay() {
        let cell = SystemCell(frame: CGRect(x: 0, y: 0, width: 390, height: 34))
        cell.configure(text: "Alfa joined")
        cell.layoutIfNeeded()
        let label = cell.contentView.subviews.compactMap { $0 as? UILabel }.first
        XCTAssertEqual(label?.center.y ?? 0, cell.contentView.bounds.midY + FeedNote.gapShift, accuracy: 0.5)
    }
}
