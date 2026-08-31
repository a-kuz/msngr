import UIKit
import SwiftUI
import MsngrCore

/// The poll bubble: the question, the options, and the results once this
/// device has voted (or the poll is its author's). A tap on an option votes;
/// tapping the chosen option again takes the vote back, and a multiple-answer
/// poll toggles options one by one — every tap sends the whole current choice.
final class PollMessageView: UIView {
    /// The full set of chosen indices after the tap.
    var onVote: (([Int]) -> Void)?

    private let questionLabel = UILabel()
    private let metaLabel = UILabel()
    private let footerLabel = UILabel()
    private var rows: [PollOptionRow] = []
    private var msg: Message?
    private var ownUserId = ""
    /// The message the current subviews were built for: results for the same
    /// poll animate, a reused cell rebuilds silently.
    private var shownId = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        questionLabel.numberOfLines = 0
        metaLabel.numberOfLines = 1
        footerLabel.numberOfLines = 1
        addSubview(questionLabel)
        addSubview(metaLabel)
        addSubview(footerLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Metrics shared with the layout plan

    private static var innerPad: CGFloat { TypeScale.scaled(2, max: 4) }
    private static var rowGap: CGFloat { TypeScale.scaled(6, max: 10) }
    private static var iconSpan: CGFloat { TypeScale.scaled(30, max: 44) }
    private static var percentSpan: CGFloat { TypeScale.scaled(46, max: 64) }
    private static var barHeight: CGFloat { TypeScale.scaled(4, max: 7) }

    private static func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return ceil(rect.height)
    }

    static func rowHeight(_ option: String, width: CGFloat) -> CGFloat {
        let textW = width - iconSpan - percentSpan
        let textH = textHeight(option, font: Theme.Text.pollOption.uiFont, width: textW)
        return max(TypeScale.scaled(34, max: 52), textH + barHeight + TypeScale.scaled(12, max: 18))
    }

    /// The whole plate's height for the layout plan.
    static func height(for poll: PollInfo, width: CGFloat) -> CGFloat {
        var h = innerPad
        h += textHeight(poll.question, font: Theme.Text.pollQuestion.uiFont, width: width)
        h += TypeScale.scaled(18, max: 28)   // the meta line under the question
        for option in poll.options {
            h += rowGap + rowHeight(option, width: width)
        }
        h += TypeScale.scaled(22, max: 34)   // the footer with the voter count
        return h + innerPad
    }

    // MARK: - Configure

    func configure(msg: Message, outgoing: Bool, ownUserId: String) {
        guard let poll = msg.poll else { return }
        let sameMessage = shownId == msg.id
        shownId = msg.id
        self.msg = msg
        self.ownUserId = ownUserId

        let textColor = outgoing ? UIColor(Theme.outgoingText) : .label
        let metaColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
        let tint = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)

        questionLabel.font = Theme.Text.pollQuestion.uiFont
        questionLabel.textColor = textColor
        questionLabel.text = poll.question
        metaLabel.font = Theme.Text.pollMeta.uiFont
        metaLabel.textColor = metaColor
        var meta = poll.anonymous ? String(localized: "Anonymous poll") : String(localized: "Poll")
        if poll.multiple { meta += " · " + String(localized: "several answers") }
        metaLabel.text = meta
        footerLabel.font = Theme.Text.pollMeta.uiFont
        footerLabel.textColor = metaColor

        if rows.count != poll.options.count || !sameMessage {
            rows.forEach { $0.removeFromSuperview() }
            rows = poll.options.map { _ in PollOptionRow() }
            rows.forEach(addSubview)
        }

        let myVotes = Set(msg.pollVotes[ownUserId] ?? [])
        // the author sees the count from the start; everyone else earns the
        // numbers by voting
        let showResults = !msg.pollVotes.isEmpty && (outgoing || !myVotes.isEmpty)
        var counts = Array(repeating: 0, count: poll.options.count)
        for (_, picks) in msg.pollVotes {
            for i in picks where i < counts.count { counts[i] += 1 }
        }
        let voters = msg.pollVotes.count

        for (i, row) in rows.enumerated() {
            let fraction = voters > 0 ? CGFloat(counts[i]) / CGFloat(voters) : 0
            row.fill(text: poll.options[i],
                     picked: myVotes.contains(i),
                     fraction: showResults ? fraction : nil,
                     percent: showResults ? Int((fraction * 100).rounded()) : nil,
                     textColor: textColor, metaColor: metaColor, tint: tint,
                     animated: sameMessage)
            row.onTap = { [weak self] in self?.tapped(i) }
        }

        footerLabel.text = voters == 0
            ? String(localized: "Nobody has voted yet")
            : String(localized: "\(voters) voted")
        setNeedsLayout()
    }

    private func tapped(_ index: Int) {
        guard let msg, let poll = msg.poll else { return }
        var picks = Set(msg.pollVotes[ownUserId] ?? [])
        if poll.multiple {
            if picks.contains(index) { picks.remove(index) } else { picks.insert(index) }
        } else {
            picks = picks.contains(index) ? [] : [index]
        }
        Haptics.light()
        onVote?(picks.sorted())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let poll = msg?.poll else { return }
        let w = bounds.width
        var y = Self.innerPad
        let qh = Self.textHeight(poll.question, font: Theme.Text.pollQuestion.uiFont, width: w)
        questionLabel.frame = CGRect(x: 0, y: y, width: w, height: qh)
        y += qh
        metaLabel.frame = CGRect(x: 0, y: y, width: w, height: TypeScale.scaled(16, max: 26))
        y += TypeScale.scaled(18, max: 28)
        for (i, row) in rows.enumerated() where i < poll.options.count {
            let rh = Self.rowHeight(poll.options[i], width: w)
            y += Self.rowGap
            row.frame = CGRect(x: 0, y: y, width: w, height: rh)
            y += rh
        }
        footerLabel.frame = CGRect(x: 0, y: y + TypeScale.scaled(4, max: 8),
                                   width: w, height: TypeScale.scaled(16, max: 24))
    }
}

/// One option: the pick mark, the text, the percent and the share bar.
private final class PollOptionRow: UIControl {
    var onTap: (() -> Void)?

    private let mark = UIImageView()
    private let textLabel = UILabel()
    private let percentLabel = UILabel()
    private let bar = UIView()
    private let track = UIView()
    private var fraction: CGFloat?
    private var wasPicked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        textLabel.numberOfLines = 0
        percentLabel.textAlignment = .right
        mark.contentMode = .scaleAspectFit
        track.isUserInteractionEnabled = false
        bar.isUserInteractionEnabled = false
        textLabel.isUserInteractionEnabled = false
        mark.isUserInteractionEnabled = false
        percentLabel.isUserInteractionEnabled = false
        [mark, textLabel, percentLabel, track, bar].forEach(addSubview)
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    func fill(text: String, picked: Bool, fraction: CGFloat?, percent: Int?,
              textColor: UIColor, metaColor: UIColor, tint: UIColor, animated: Bool) {
        textLabel.font = Theme.Text.pollOption.uiFont
        textLabel.textColor = textColor
        textLabel.text = text
        percentLabel.font = Theme.Text.pollPercent.uiFont
        percentLabel.textColor = textColor
        mark.tintColor = tint
        mark.image = UIImage(systemName: picked ? "checkmark.circle.fill" : "circle")
        bar.backgroundColor = tint
        track.backgroundColor = metaColor.withAlphaComponent(0.25)

        // the pick mark pops when this very row was just chosen
        if picked && !wasPicked && animated {
            mark.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.55,
                           initialSpringVelocity: 0) { self.mark.transform = .identity }
        }
        wasPicked = picked

        let hadResults = self.fraction != nil
        self.fraction = fraction
        if let percent {
            if percentLabel.text != nil && animated {
                UIView.transition(with: percentLabel, duration: 0.25, options: .transitionCrossDissolve) {
                    self.percentLabel.text = "\(percent)%"
                }
            } else {
                percentLabel.text = "\(percent)%"
            }
        } else {
            percentLabel.text = nil
        }
        percentLabel.isHidden = percent == nil
        track.isHidden = fraction == nil
        bar.isHidden = fraction == nil

        setNeedsLayout()
        if animated, fraction != nil {
            // the share bars grow into place: from zero when the results have
            // just been earned, from the previous share on a new vote
            if !hadResults { layoutIfNeeded(); bar.frame.size.width = 0 }
            UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0) { self.layoutIfNeeded() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconSpan = TypeScale.scaled(30, max: 44)
        let percentSpan = TypeScale.scaled(46, max: 64)
        let barH = TypeScale.scaled(4, max: 7)
        let markSide = TypeScale.scaled(22, max: 34)
        mark.frame = CGRect(x: 0, y: TypeScale.scaled(2, max: 4), width: markSide, height: markSide)
        let textW = bounds.width - iconSpan - percentSpan
        let textH = bounds.height - barH - TypeScale.scaled(10, max: 16)
        textLabel.frame = CGRect(x: iconSpan, y: 0, width: textW, height: textH)
        percentLabel.frame = CGRect(x: bounds.width - percentSpan, y: 0,
                                    width: percentSpan, height: TypeScale.scaled(20, max: 32))
        let trackFrame = CGRect(x: iconSpan, y: bounds.height - barH,
                                width: bounds.width - iconSpan, height: barH)
        track.frame = trackFrame
        track.layer.cornerRadius = barH / 2
        bar.frame = CGRect(x: trackFrame.minX, y: trackFrame.minY,
                           width: trackFrame.width * (fraction ?? 0), height: barH)
        bar.layer.cornerRadius = barH / 2
    }
}

/// Composing a poll: the question, two to ten options, and the two switches.
struct PollComposerSheet: View {
    var onCreate: (PollInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var multiple = false
    @State private var anonymous = false

    private var trimmedOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var ready: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmedOptions.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Question")) {
                    TextField(String(localized: "Ask a question"), text: $question, axis: .vertical)
                        .accessibilityIdentifier("poll.question")
                }
                Section(String(localized: "Options")) {
                    ForEach(options.indices, id: \.self) { i in
                        TextField(String(localized: "Option"), text: $options[i])
                            .accessibilityIdentifier("poll.option.\(i)")
                    }
                    .onDelete { options.remove(atOffsets: $0); ensureFloor() }
                    if options.count < 10 {
                        Button(String(localized: "Add an option")) { options.append("") }
                            .accessibilityIdentifier("poll.addOption")
                    }
                }
                Section {
                    Toggle(String(localized: "Several answers"), isOn: $multiple)
                    Toggle(String(localized: "Anonymous voting"), isOn: $anonymous)
                } footer: {
                    if anonymous {
                        Text(String(localized: "Votes still travel end-to-end encrypted between the members; the app just never shows who chose what."))
                    }
                }
            }
            .navigationTitle(String(localized: "Poll"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create")) {
                        onCreate(PollInfo(question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                                          options: trimmedOptions,
                                          multiple: multiple, anonymous: anonymous))
                        dismiss()
                    }
                    .disabled(!ready)
                    .accessibilityIdentifier("poll.create")
                }
            }
        }
    }

    private func ensureFloor() {
        while options.count < 2 { options.append("") }
    }
}
