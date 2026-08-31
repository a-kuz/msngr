import UIKit
import MsngrCore

/// The call row in the feed: a phone glyph in a circle, the call's direction
/// and how it ended. A tap dials the peer again.
final class CallMessageView: UIView {
    var onRedial: (() -> Void)?

    private let circle = UIView()
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        circle.clipsToBounds = true
        glyph.contentMode = .scaleAspectFit
        titleLabel.numberOfLines = 1
        detailLabel.numberOfLines = 1
        addSubview(circle)
        circle.addSubview(glyph)
        addSubview(titleLabel)
        addSubview(detailLabel)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isUserInteractionEnabled = true
        accessibilityIdentifier = "message.call"
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onRedial?() }

    func configure(msg: Message, outgoing: Bool) {
        let log = msg.callLog
        let missedIncoming = !outgoing && log.map {
            $0.outcome == .missed || $0.outcome == .declined
        } ?? false
        glyph.image = UIImage(systemName: outgoing ? "phone.arrow.up.right" : "phone.arrow.down.left")
        let accent: UIColor = missedIncoming ? .systemRed
            : outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        glyph.tintColor = accent
        circle.backgroundColor = accent.withAlphaComponent(outgoing ? 0.25 : 0.15)
        titleLabel.text = Self.title(outgoing: outgoing, log: log)
        titleLabel.font = Theme.Text.fileName.uiFont
        titleLabel.textColor = outgoing ? UIColor(Theme.outgoingText) : .label
        detailLabel.text = Self.detail(outgoing: outgoing, log: log)
        detailLabel.font = Theme.Text.voiceDuration.uiFont
        detailLabel.textColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
        setNeedsLayout()
    }

    static func title(outgoing: Bool, log: CallLog?) -> String {
        if !outgoing, let log, log.outcome == .missed {
            return String(localized: "Missed call")
        }
        return outgoing ? String(localized: "Outgoing call") : String(localized: "Incoming call")
    }

    static func detail(outgoing: Bool, log: CallLog?) -> String {
        guard let log else { return String(localized: "Call") }
        switch log.outcome {
        case .completed:
            let s = max(0, Int(log.duration ?? 0))
            return String(format: "%d:%02d", s / 60, s % 60)
        case .missed:
            // the incoming title already says "Missed call"; repeating it below
            // reads as a stutter
            return outgoing ? String(localized: "No answer") : ""
        case .declined:
            return String(localized: "Call declined")
        case .busy:
            return String(localized: "Busy")
        case .failed:
            return String(localized: "Call failed")
        }
    }

    /// The one-line form for the chat list preview.
    static func preview(_ msg: Message) -> String {
        title(outgoing: msg.isOutgoing, log: msg.callLog)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = min(bounds.height - 8, TypeScale.scaled(36, max: 64))
        circle.frame = CGRect(x: 4, y: (bounds.height - d) / 2, width: d, height: d)
        circle.layer.cornerRadius = d / 2
        glyph.frame = circle.bounds.insetBy(dx: d * 0.26, dy: d * 0.26)
        let x = circle.frame.maxX + 10
        let w = bounds.width - x - 4
        let titleH = ceil(Theme.Text.fileName.uiFont.lineHeight)
        let detailH = ceil(Theme.Text.voiceDuration.uiFont.lineHeight)
        let top = (bounds.height - titleH - detailH - 2) / 2
        titleLabel.frame = CGRect(x: x, y: top, width: w, height: titleH)
        detailLabel.frame = CGRect(x: x, y: titleLabel.frame.maxY + 2, width: w, height: detailH)
    }
}
