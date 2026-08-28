import XCTest
@testable import Msngr

/// The date capsule sits shifted toward the older day: the first message of
/// the new day brings its own series gap on the other side.
final class DateSeparatorSpacingTests: XCTestCase {

    private func capsule(in cell: DateSeparatorCell) -> UIView? {
        cell.contentView.subviews.first { $0 is DateCapsuleView }
    }

    func testTheCapsuleLeansTowardTheOlderDay() {
        let cell = DateSeparatorCell(frame: CGRect(x: 0, y: 0, width: 390, height: 34))
        cell.configure("Сегодня")
        let capsule = capsule(in: cell)
        XCTAssertNotNil(capsule)
        XCTAssertEqual(capsule?.center.y ?? 0,
                       cell.contentView.bounds.midY + DateSeparatorCell.olderSideShift,
                       accuracy: 0.5)
        XCTAssertEqual(capsule?.center.x ?? 0, cell.contentView.bounds.midX, accuracy: 0.5)
    }

    func testTheShiftEvensOutTheSeriesGap() {
        // 5pt of cell padding plus the shift on one side, 5pt minus the shift
        // plus the neighbour's normalGap on the other: both come out equal
        XCTAssertEqual(DateSeparatorCell.olderSideShift * 2, BubbleLayout.normalGap)
    }
}
