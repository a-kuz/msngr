import UIKit
import MapKit
import MsngrCore

/// The contact bubble: an initials circle, the name and the first phone.
/// A tap anywhere opens the card sheet.
final class ContactMessageView: UIView {
    var onOpen: (() -> Void)?

    private let circle = UILabel()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        circle.textAlignment = .center
        circle.clipsToBounds = true
        nameLabel.numberOfLines = 1
        detailLabel.numberOfLines = 1
        addSubview(circle)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isUserInteractionEnabled = true
        accessibilityIdentifier = "message.contact"
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onOpen?() }

    func configure(msg: Message, outgoing: Bool) {
        guard let card = msg.contact else { return }
        let initials = card.name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }.joined()
        circle.text = initials.isEmpty ? "?" : initials
        circle.font = Theme.Text.pollPercent.uiFont
        circle.backgroundColor = outgoing
            ? UIColor(Theme.outgoingText).withAlphaComponent(0.25)
            : UIColor(Theme.accent).withAlphaComponent(0.2)
        circle.textColor = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        nameLabel.text = card.name
        nameLabel.font = Theme.Text.fileName.uiFont
        nameLabel.textColor = outgoing ? UIColor(Theme.outgoingText) : .label
        detailLabel.text = card.phones.first ?? card.emails.first
        detailLabel.font = Theme.Text.voiceDuration.uiFont
        detailLabel.textColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let d = min(bounds.height - 8, TypeScale.scaled(36, max: 64))
        circle.frame = CGRect(x: 4, y: (bounds.height - d) / 2, width: d, height: d)
        circle.layer.cornerRadius = d / 2
        let x = circle.frame.maxX + 10
        let w = bounds.width - x - 4
        let nameH = ceil(Theme.Text.fileName.uiFont.lineHeight)
        let detailH = ceil(Theme.Text.voiceDuration.uiFont.lineHeight)
        let top = (bounds.height - nameH - detailH - 2) / 2
        nameLabel.frame = CGRect(x: x, y: top, width: w, height: nameH)
        detailLabel.frame = CGRect(x: x, y: nameLabel.frame.maxY + 2, width: w, height: detailH)
    }
}

/// The location bubble: a map snapshot with a pin at the shared point and the
/// sender's label over the lower edge. A tap opens the full map.
final class LocationMessageView: UIView {
    var onOpen: (() -> Void)?

    private let imageView = UIImageView()
    private let pin = UIImageView(image: UIImage(systemName: "mappin.circle.fill"))
    private let nameBar = UILabel()
    private var shownKey = ""

    /// Snapshots are costly to render and identical across reuse: one per
    /// (point, size, appearance) for the life of the process.
    private static let cache = NSCache<NSString, UIImage>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 12
        pin.tintColor = .systemRed
        nameBar.font = Theme.Text.voiceDuration.uiFont
        nameBar.textColor = .white
        nameBar.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        nameBar.textAlignment = .center
        nameBar.clipsToBounds = true
        nameBar.layer.cornerRadius = 8
        addSubview(imageView)
        addSubview(pin)
        addSubview(nameBar)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isUserInteractionEnabled = true
        accessibilityIdentifier = "message.location"
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onOpen?() }

    func configure(msg: Message) {
        guard let point = msg.location else { return }
        nameBar.text = point.name
        nameBar.isHidden = point.name?.isEmpty != false
        let key = "\(point.lat),\(point.lon),\(Int(bounds.width))x\(Int(bounds.height))," +
            "\(traitCollection.userInterfaceStyle.rawValue)"
        guard key != shownKey else { return }
        shownKey = key
        if let hit = Self.cache.object(forKey: key as NSString) {
            imageView.image = hit
            return
        }
        imageView.image = nil
        let options = MKMapSnapshotter.Options()
        let center = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
        options.region = MKCoordinateRegion(center: center,
                                            latitudinalMeters: 600, longitudinalMeters: 600)
        options.size = bounds.size == .zero ? CGSize(width: 280, height: 168) : bounds.size
        options.traitCollection = traitCollection
        MKMapSnapshotter(options: options).start { [weak self] snapshot, _ in
            guard let self, let snapshot, self.shownKey == key else { return }
            Self.cache.setObject(snapshot.image, forKey: key as NSString)
            self.imageView.image = snapshot.image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        let s = TypeScale.scaled(30, max: 44)
        pin.frame = CGRect(x: (bounds.width - s) / 2, y: bounds.height / 2 - s,
                           width: s, height: s)
        let h = ceil(Theme.Text.voiceDuration.uiFont.lineHeight) + 8
        nameBar.frame = CGRect(x: 8, y: bounds.height - h - 8, width: bounds.width - 16, height: h)
    }
}
