#if canImport(UIKit)
import DesignSystem
import UIKit

/// One tab in the sidebar: a site tile (the first letter of its host until site icons are stored),
/// then its title and a close button. The cell is always as wide as the expanded sidebar; the
/// sidebar clips it, so the rail shows the tile alone and a resize never lays a cell out again.
final class SideTabCell: UICollectionViewCell {
    static let reuseID = "SideTabCell"

    /// The close button was tapped.
    var onClose: (() -> Void)?

    private let highlight = UIView()
    private let tile = UIView()
    private let letter = UILabel()
    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    static let height: CGFloat = 48
    static let tileSize: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        highlight.layer.cornerRadius = Radius.large
        highlight.layer.cornerCurve = .continuous
        contentView.addSubview(highlight)

        tile.layer.cornerRadius = Radius.medium
        tile.layer.cornerCurve = .continuous
        tile.backgroundColor = Palette.surface
        contentView.addSubview(tile)
        letter.font = UIFont.preferredFont(forTextStyle: .headline)
        letter.adjustsFontForContentSizeCategory = false
        letter.textAlignment = .center
        letter.textColor = Palette.textSecondary
        tile.addSubview(letter)
        symbol.contentMode = .center
        symbol.tintColor = Palette.textSecondary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        tile.addSubview(symbol)

        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)),
            for: .normal
        )
        closeButton.tintColor = Palette.textSecondary
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        contentView.addSubview(closeButton)

        isAccessibilityElement = true
        accessibilityIdentifier = "sideTab"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: SideTabCell, _) in
            cell.resolveBorder()
        }
    }

    private var isInOtherPane = false

    private func resolveBorder() {
        let color = isInOtherPane ? UIColor.separator : Palette.accentOnGlass
        highlight.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lays the row out for `item`. `isFocused`: the focused pane shows it; `isInOtherPane`: the
    /// split's other pane does; `railWidth`: where the tile centers.
    func configure(item: TabGalleryItem, isFocused: Bool, isInOtherPane: Bool, showsTitle: Bool) {
        titleLabel.text = item.displayTitle
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(isFocused ? .semibold : .regular)
        if let first = Self.siteName(of: item.host)?.first {
            letter.text = String(first).uppercased()
            symbol.image = nil
        } else {
            letter.text = nil
            symbol.image = UIImage(systemName: item.isPrivate ? "hand.raised" : "globe")
        }
        tile.backgroundColor = item.isPrivate ? Palette.privateBackground : Palette.surface
        // The focused pane's tab is the strong mark (tinted, with the pane ring's color); the other
        // pane's only a quiet outline.
        highlight.backgroundColor = isFocused ? Palette.pressed : .clear
        highlight.layer.borderWidth = isFocused ? 1.5 : (isInOtherPane ? 1 : 0)
        self.isInOtherPane = isInOtherPane && !isFocused
        resolveBorder()
        // Hidden behind the clip in the rail anyway; out of the accessibility tree there too.
        titleLabel.isHidden = !showsTitle
        closeButton.isHidden = !showsTitle
        accessibilityLabel = item.displayTitle
        accessibilityValue = isFocused ? "Selected" : (isInOtherPane ? "In other pane" : nil)
        accessibilityTraits = isFocused ? [.button, .selected] : .button
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Close Tab") { [weak self] _ in
                self?.onClose?()
                return true
            },
        ]
    }

    /// The site's own name in `host`, for the tile's letter: "wikipedia" in en.wikipedia.org,
    /// "ycombinator" in news.ycombinator.com, "bbc" in www.bbc.co.uk.
    static func siteName(of host: String?) -> String? {
        guard let host else { return nil }
        var labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1 else { return labels.first }
        labels.removeLast()
        // A short second level under a country code (co.uk, com.au) is not the site's name.
        if labels.count > 1, let last = labels.last, last.count <= 3, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(last) {
            labels.removeLast()
        }
        return labels.last
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let rail = SidebarState.rail.width
        let inset = Spacing.xs
        highlight.frame = CGRect(x: inset + Spacing.xxs, y: inset / 2, width: bounds.width - 2 * (inset + Spacing.xxs), height: bounds.height - inset)
        let size = Self.tileSize
        tile.frame = CGRect(x: (rail - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        letter.frame = tile.bounds
        symbol.frame = tile.bounds
        let closeSize = Metrics.tapTarget
        closeButton.frame = CGRect(x: bounds.width - closeSize - inset, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        let titleX = rail
        titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, closeButton.frame.minX - titleX), height: bounds.height)
    }
}
#endif
