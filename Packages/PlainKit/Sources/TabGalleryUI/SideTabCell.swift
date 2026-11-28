#if canImport(UIKit)
import DesignSystem
import UIKit

/// The sidebar's row geometry, shared by its tab rows and its own rows (New Tab, Show Titles), so
/// every tile stands in one column and every label starts on one line.
enum SideTabMetrics {
    /// A row: one 44 pt target.
    static let rowHeight: CGFloat = Metrics.tapTarget
    /// A tab's tile.
    static let tileSize: CGFloat = 32
    /// The site icon inside the tile.
    static let iconSize: CGFloat = 20
    /// The selection mark's inset from the sidebar's edges and from the rows above and below.
    static let markInset = CGSize(width: Spacing.xs, height: Spacing.xxs)
    /// The rail's width: where the tiles' column ends and the titles begin.
    static var rail: CGFloat { SidebarState.rail.width }
    static var expanded: CGFloat { SidebarState.expanded.width }

    /// The tile's frame in a row of `height`.
    static func tileFrame(rowHeight height: CGFloat) -> CGRect {
        CGRect(x: (rail - tileSize) / 2, y: (height - tileSize) / 2, width: tileSize, height: tileSize)
    }

    /// The selection mark's frame while the sidebar shows `visibleWidth` of the row: it spans what
    /// shows, so the sidebar's clip never cuts its edge, from the rail to Expanded.
    static func markFrame(rowHeight height: CGFloat, visibleWidth: CGFloat) -> CGRect {
        let width = min(max(visibleWidth, rail), expanded)
        return CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: markInset.width, dy: markInset.height)
    }

    /// How far the titles and close buttons have come in (0 in the rail and over the first third
    /// of the way, 1 from four fifths): they fade in together once there is room for a few words,
    /// not as clipped fragments behind the edge, and are gone before the rail closes over them.
    static func titleAlpha(visibleWidth: CGFloat) -> CGFloat {
        let progress = (visibleWidth - rail) / max(1, expanded - rail)
        return min(max((progress - 0.35) / 0.45, 0), 1)
    }
}

/// One tab in the sidebar: its site icon on a tile, then its title and a close button. The cell is
/// always as wide as the expanded sidebar; the sidebar clips it, so the rail shows the tile alone
/// and a resize never lays a cell out again. Only the selection mark's width and the title's
/// opacity follow the sidebar's width (`setVisibleWidth`).
final class SideTabCell: UICollectionViewCell {
    static let reuseID = "SideTabCell"

    /// The close button was tapped.
    var onClose: (() -> Void)?

    private let mark = UIView()
    private let tile = SiteIconView(side: SideTabMetrics.tileSize, iconSide: SideTabMetrics.iconSize, radius: Radius.medium)
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private enum Mark { case none, focused, otherPane }
    private var markState = Mark.none
    private var isPrivate = false
    private var visibleWidth = SideTabMetrics.rail
    /// The tab the cell shows: a change of its mark animates only for the same tab.
    private var shownID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        mark.layer.cornerRadius = Radius.large
        mark.layer.cornerCurve = .continuous
        mark.alpha = 0
        mark.isUserInteractionEnabled = false
        contentView.addSubview(mark)
        contentView.addSubview(tile)

        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        // The row is one 44 pt line: the title stops growing at the largest standard size.
        titleLabel.maximumContentSizeCategory = .extraExtraExtraLarge
        titleLabel.textColor = Palette.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)),
            for: .normal
        )
        closeButton.tintColor = Palette.textSecondary
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.accessibilityIdentifier = "sideTab.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .primaryActionTriggered)
        contentView.addSubview(closeButton)

        isAccessibilityElement = true
        accessibilityIdentifier = "sideTab"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: SideTabCell, _) in
            cell.resolveBorder()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        shownID = nil
        tile.transform = .identity
    }

    /// Shows `item`. `isFocused`: the focused pane shows it (the Lagoon mark); `isInOtherPane`: the
    /// split's other pane does (a quiet outline); `visibleWidth`: how much of the row the sidebar
    /// shows now.
    func configure(
        item: TabGalleryItem, isFocused: Bool, isInOtherPane: Bool, visibleWidth: CGFloat, icons: any SideTabsDataSource
    ) {
        let sameTab = shownID == item.id
        shownID = item.id
        titleLabel.text = item.compactTitle
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(isFocused ? .semibold : .regular)
        tile.show(item, from: icons)

        let state: Mark = isFocused ? .focused : (isInOtherPane ? .otherPane : .none)
        let wasPrivate = isPrivate
        isPrivate = item.isPrivate
        if state != markState || wasPrivate != isPrivate || !sameTab {
            let changes = {
                self.markState = state
                self.applyMark()
            }
            // The mark fades from the tab left to the tab chosen; nothing moves.
            if sameTab, window != nil {
                Motion.animate(Motion.quick, changes: changes)
            } else {
                UIView.performWithoutAnimation(changes)
            }
        }
        setVisibleWidth(visibleWidth)

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

    private func applyMark() {
        switch markState {
        case .none:
            // A tab not on screen: in the rail its tile is its shape; with titles, the row gets
            // a plate of its own (`setVisibleWidth` fades it in with the title).
            mark.backgroundColor = isPrivate ? Palette.privateTabPlate : Palette.tabPlate
            mark.layer.borderWidth = 0.5
            mark.alpha = SideTabMetrics.titleAlpha(visibleWidth: visibleWidth)
        case .focused:
            // The tab on screen: Lagoon, tinted with the pane ring's color around it.
            mark.backgroundColor = Palette.pressed
            mark.layer.borderWidth = 1.5
            mark.alpha = 1
        case .otherPane:
            mark.backgroundColor = .clear
            mark.layer.borderWidth = 1
            mark.alpha = 1
        }
        resolveBorder()
    }

    private func resolveBorder() {
        let color: UIColor = switch markState {
        case .focused: Palette.accentOnGlass
        case .otherPane: .separator
        case .none: Palette.tabPlateEdge
        }
        mark.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    /// The sidebar shows `width` of the row now. Sets a frame and two opacities; inside an
    /// animation they follow the sidebar's spring.
    func setVisibleWidth(_ width: CGFloat) {
        visibleWidth = width
        mark.frame = SideTabMetrics.markFrame(rowHeight: contentView.bounds.height, visibleWidth: width)
        let alpha = SideTabMetrics.titleAlpha(visibleWidth: width)
        if markState == .none { mark.alpha = alpha }
        titleLabel.alpha = alpha
        closeButton.alpha = alpha
        // Behind the clip in the rail: no taps there.
        closeButton.isUserInteractionEnabled = alpha > 0.5
    }

    /// Where VoiceOver, Switch Control and UI tests touch the row: its tile, which shows in the
    /// rail too. The row is as wide as the titled sidebar, so its middle is under the page while
    /// the rail clips it, and a touch there went to the page.
    override var accessibilityActivationPoint: CGPoint {
        get {
            let tile = SideTabMetrics.tileFrame(rowHeight: bounds.height)
            return UIAccessibility.convertToScreenCoordinates(tile, in: self).center
        }
        set {}
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            // The tile gives under the finger.
            let scale: CGFloat = isHighlighted ? 0.92 : 1
            Motion.animate(Motion.quick) {
                self.tile.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        mark.frame = SideTabMetrics.markFrame(rowHeight: bounds.height, visibleWidth: visibleWidth)
        let transform = tile.transform
        tile.transform = .identity
        tile.frame = SideTabMetrics.tileFrame(rowHeight: bounds.height)
        tile.transform = transform
        let closeSize = Metrics.tapTarget
        closeButton.frame = CGRect(
            x: bounds.width - closeSize - SideTabMetrics.markInset.width, y: (bounds.height - closeSize) / 2,
            width: closeSize, height: closeSize
        )
        let titleX = SideTabMetrics.rail
        titleLabel.frame = CGRect(x: titleX, y: 0, width: max(0, closeButton.frame.minX - titleX), height: bounds.height)
    }
}

/// One of the sidebar's own rows (New Tab, Show Titles): a symbol where the tabs' tiles stand and
/// its name where their titles start, so it reads as a button in the rail and as a row in Expanded.
final class SideActionRow: UIControl {
    private let tile = UIView()
    private let symbol = UIImageView()
    private let label = UILabel()

    /// - Parameter prominent: the row's symbol sits on a Lagoon-tinted tile (New Tab).
    init(symbolName: String, title: String, prominent: Bool) {
        super.init(frame: .zero)
        tile.layer.cornerRadius = Radius.medium
        tile.layer.cornerCurve = .continuous
        tile.backgroundColor = prominent ? Palette.pressed : .clear
        tile.isUserInteractionEnabled = false
        addSubview(tile)
        symbol.contentMode = .center
        symbol.tintColor = prominent ? Palette.accentOnPaper : Palette.inkSecondary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: prominent ? .medium : .small)
        tile.addSubview(symbol)
        label.font = UIFont.preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.maximumContentSizeCategory = .extraExtraExtraLarge
        label.textColor = prominent ? Palette.accentOnPaper : Palette.inkSecondary
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
        showsLargeContentViewer = true
        addInteraction(UILargeContentViewerInteraction())
        // A plain control sends no primary action of its own (only UIButton does): a touch that
        // ends inside is the row's action. Without this New Tab and Show Titles took no taps.
        addAction(UIAction { [weak self] _ in self?.sendActions(for: .primaryActionTriggered) }, for: .touchUpInside)
        set(symbolName: symbolName, title: title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A long press offers this menu (New Tab: New Private Tab).
    var menu: UIMenu? {
        didSet { isContextMenuInteractionEnabled = menu != nil }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }

    func set(symbolName: String, title: String) {
        symbol.image = UIImage(systemName: symbolName)
        label.text = title
        accessibilityLabel = title
        largeContentTitle = title
        largeContentImage = symbol.image
    }

    func setVisibleWidth(_ width: CGFloat) {
        label.alpha = SideTabMetrics.titleAlpha(visibleWidth: width)
    }

    /// Where VoiceOver, Switch Control and UI tests touch the row: its tile, which shows in the
    /// rail too. The row is as wide as the titled sidebar, so its middle is under the page while
    /// the rail clips it, and a touch there went to the page.
    override var accessibilityActivationPoint: CGPoint {
        get {
            let tile = SideTabMetrics.tileFrame(rowHeight: bounds.height)
            return UIAccessibility.convertToScreenCoordinates(tile, in: self).center
        }
        set {}
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let scale: CGFloat = isHighlighted ? 0.92 : 1
            Motion.animate(Motion.quick) {
                self.tile.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let transform = tile.transform
        tile.transform = .identity
        tile.frame = SideTabMetrics.tileFrame(rowHeight: bounds.height)
        tile.transform = transform
        symbol.frame = tile.bounds
        let x = SideTabMetrics.rail
        label.frame = CGRect(x: x, y: 0, width: max(0, bounds.width - x - Spacing.m), height: bounds.height)
    }
}
#endif

#if canImport(UIKit)
private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
#endif
