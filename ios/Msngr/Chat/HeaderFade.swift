import SwiftUI
import UIKit

/// The band under the floating header: a message leaving the feed dissolves
/// into it instead of being cut by its edge. Blur and the background tone both
/// gather towards the top edge, over the height of the header.
struct HeaderFade: UIViewRepresentable {
    /// Feed background: the band takes its tone from the palette.
    let tone: Color

    func makeUIView(context: Context) -> HeaderFadeView { HeaderFadeView() }

    func updateUIView(_ view: HeaderFadeView, context: Context) {
        view.tone = UIColor(tone)
    }
}

/// The gradient of blur is stacked: every layer blurs what is behind it,
/// previous layers included, so all of them meet at the top edge while the
/// bottom of the band carries the first one alone.
final class HeaderFadeView: UIView {
    /// Share of the band height, measured from the top edge: how far a layer
    /// holds at full strength and where it runs out.
    private static let spans: [(solid: CGFloat, fade: CGFloat)] = [
        (0.50, 1.00),
        (0.36, 0.74),
        (0.24, 0.52),
        (0.12, 0.32),
    ]

    /// The tone closes the feed off at the edge and lets it through below.
    private static let toneStops: [(location: CGFloat, alpha: CGFloat)] = [
        (0.00, 1.00),
        (0.30, 0.82),
        (0.58, 0.42),
        (0.80, 0.14),
        (1.00, 0.00),
    ]

    /// Header height without the status bar.
    private static let barHeight: CGFloat = 44

    var tone: UIColor = .clear {
        didSet {
            guard tone != oldValue else { return }
            applyTone()
        }
    }

    private let blurs: [UIVisualEffectView]
    private let blurMasks: [CAGradientLayer]
    private let toneLayer = CAGradientLayer()

    override init(frame: CGRect) {
        blurs = HeaderFadeView.spans.map { _ in
            UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }
        blurMasks = HeaderFadeView.spans.map { _ in CAGradientLayer() }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for (blur, mask) in zip(blurs, blurMasks) {
            mask.colors = [UIColor.white.cgColor, UIColor.white.cgColor,
                           UIColor.white.withAlphaComponent(0).cgColor]
            blur.layer.mask = mask
            addSubview(blur)
        }
        layer.addSublayer(toneLayer)
        applyTone()
        // the tone is a CALayer colour, so it is resolved by hand and has to be
        // resolved again when the appearance changes
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HeaderFadeView, _) in
            view.applyTone()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The band lives at the top edge only: the rest of the view stays empty,
    /// there is nothing to gain from blurring the whole feed.
    override func layoutSubviews() {
        super.layoutSubviews()
        // the status bar alone: the view's own inset already carries the header,
        // and the band would double its height
        let statusBar = window?.safeAreaInsets.top ?? safeAreaInsets.top
        let height = statusBar + HeaderFadeView.barHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, span) in HeaderFadeView.spans.enumerated() {
            blurs[index].frame = CGRect(x: 0, y: 0, width: bounds.width,
                                        height: height * span.fade)
            let mask = blurMasks[index]
            mask.frame = blurs[index].bounds
            mask.locations = [0, NSNumber(value: Double(span.solid / span.fade)), 1]
        }
        toneLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        CATransaction.commit()
    }

    private func applyTone() {
        let resolved = tone.resolvedColor(with: traitCollection)
        toneLayer.colors = HeaderFadeView.toneStops.map {
            resolved.withAlphaComponent($0.alpha).cgColor
        }
        toneLayer.locations = HeaderFadeView.toneStops.map { NSNumber(value: Double($0.location)) }
    }
}
