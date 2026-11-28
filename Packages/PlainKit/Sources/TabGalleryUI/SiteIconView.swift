#if canImport(UIKit)
import DesignSystem
import UIKit
import WebEngine

/// A tab's site icon on its tile (the sidebar, the strip): the favicon once the site has one, the
/// site's first letter until then or when it has none.
///
/// The tile is a quiet lifted square, so every tab has the same shape whatever its icon; a
/// one-tone mark gets a tile that contrasts with it in both appearances (a black logo keeps a
/// light tile at night). The icon arrives decoded at this view's exact pixel size
/// (`SideTabsDataSource.icon`); this view only assigns it. An icon already in memory is assigned
/// in the same pass as the row, so a row never shows its letter first; one that has to be read
/// fades in over the letter.
final class SiteIconView: UIView {
    private let imageView = UIImageView()
    private let letter = UILabel()
    private let symbol = UIImageView()
    private let iconSide: CGFloat

    /// What is shown, or being loaded: a new site or a new revision of its icon starts a load.
    private struct Shown: Equatable {
        /// The tab: another tab's row never keeps this one's icon (another profile's tab on the
        /// same site has its own).
        var tab: UUID
        var site: String?
        var revision: Int
        var isPrivate: Bool
        var pixelSize: Int
    }
    private var shown: Shown?
    private var style: SiteIconStyle?
    private var isPrivate = false
    private var load: Task<Void, Never>?

    /// - Parameters:
    ///   - side: the tile's side.
    ///   - iconSide: the icon's side inside it.
    init(side: CGFloat, iconSide: CGFloat, radius: CGFloat) {
        self.iconSide = iconSide
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / max(1, traitCollection.displayScale)
        isUserInteractionEnabled = false

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = max(2, iconSide * 0.2)
        imageView.layer.cornerCurve = .continuous
        imageView.alpha = 0
        addSubview(imageView)

        // The site's letter in New York, the face of Plain's titles.
        let size = (iconSide * 0.74).rounded()
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        letter.font = base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        letter.textAlignment = .center
        letter.textColor = Palette.inkSecondary
        addSubview(letter)

        symbol.contentMode = .center
        symbol.tintColor = Palette.inkSecondary
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
        addSubview(symbol)

        applyTile()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: SiteIconView, _) in
            view.resolveEdge()
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: SiteIconView, _) in
            // Another screen's scale: the icon is decoded again at its pixels.
            view.shown = nil
            view.layer.borderWidth = 1 / max(1, view.traitCollection.displayScale)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(iconSide, bounds.width)
        imageView.frame = CGRect(
            x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side
        )
        letter.frame = bounds
        symbol.frame = bounds
    }

    /// Shows `item`'s site: its icon from `source`, else its letter.
    func show(_ item: TabGalleryItem, from source: any SideTabsDataSource) {
        let scale = max(1, traitCollection.displayScale)
        let pixelSize = Int((iconSide * scale).rounded())
        let next = Shown(tab: item.id, site: item.host, revision: item.faviconRevision, isPrivate: item.isPrivate, pixelSize: pixelSize)
        guard next != shown else { return }
        let sameSite = shown?.tab == next.tab && shown?.site == next.site && shown?.isPrivate == next.isPrivate
        shown = next
        isPrivate = item.isPrivate
        load?.cancel()
        load = nil
        if let icon = source.cachedIcon(for: item, pixelSize: pixelSize) {
            set(icon, animated: false)
            return
        }
        // The same site's icon changed: the old one stays until the new one is decoded.
        if !(sameSite && style != nil) { showLetter(for: item) }
        guard item.url != nil else { return }
        load = Task { [weak self] in
            let icon = await source.icon(for: item, pixelSize: pixelSize)
            guard let self, !Task.isCancelled, self.shown == next else { return }
            self.load = nil
            if let icon {
                self.set(icon, animated: self.window != nil)
            } else if self.style != nil {
                self.showLetter(for: item)
            }
        }
    }

    private func showLetter(for item: TabGalleryItem) {
        style = nil
        imageView.image = nil
        imageView.alpha = 0
        if let first = TabGalleryItem.siteName(of: item.host)?.first ?? item.host?.first {
            letter.text = String(first).uppercased()
            symbol.image = nil
        } else {
            letter.text = nil
            symbol.image = UIImage(systemName: item.isPrivate ? "hand.raised" : "globe")
        }
        letter.alpha = 1
        symbol.alpha = 1
        applyTile()
    }

    private func set(_ icon: SiteIcon, animated: Bool) {
        let hadIcon = style != nil
        style = icon.style
        imageView.image = icon.image
        let changes = {
            self.imageView.alpha = 1
            self.letter.alpha = 0
            self.symbol.alpha = 0
            self.applyTile()
        }
        // The letter gives way to the icon in a short crossfade; nothing moves.
        if animated, !hadIcon {
            UIView.animate(
                withDuration: Motion.crossfadeDuration, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState],
                animations: changes
            )
        } else {
            UIView.performWithoutAnimation(changes)
        }
    }

    private func applyTile() {
        switch style {
        case .darkGlyph: backgroundColor = Palette.iconTileForDarkMark
        case .lightGlyph: backgroundColor = Palette.iconTileForLightMark
        default: backgroundColor = isPrivate ? Palette.privateBackground : Palette.surface
        }
        resolveEdge()
    }

    private func resolveEdge() {
        layer.borderColor = Palette.iconTileEdge.resolvedColor(with: traitCollection).cgColor
    }
}
#endif
