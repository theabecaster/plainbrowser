#if canImport(UIKit)
import DesignSystem
import UIKit

/// The gallery's floating bar: the gallery menu, the Private | Tabs switch, New Tab and Done, on
/// one glass capsule. A control the state rules leave out is taken out of the row and the capsule
/// fits the rest, centered (UX audit, 2026-11-27: a hidden-in-place More left the row
/// off-centre). Text is capped at the pill's size; a long press shows the Large Content Viewer.
final class GalleryBottomBar: UIView {
    let menuButton = UIButton(type: .system)
    let modeSwitch = GalleryModeSwitch()
    let newTabButton = UIButton(type: .system)
    let doneButton = UIButton(type: .system)
    /// Whether the Private | Tabs switch shows (the data source supports private tabs).
    var showsPrivateButton = false {
        didSet {
            modeSwitch.isHidden = !showsPrivateButton
            setNeedsLayout()
        }
    }
    private let glass = Glass.makeView(shape: .capsule, tint: Palette.glassTintOnPaper)
    /// Which of the optional controls are in the row (the private toggle follows
    /// `showsPrivateButton`).
    private(set) var showsMenu = true
    private(set) var showsNewTab = true
    private(set) var showsDone = true

    private static let height: CGFloat = 52
    private static let padding: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        // The pill's cap (AddressPill): past it the capsule would outgrow its row.
        maximumContentSizeCategory = .extraExtraExtraLarge
        addInteraction(UILargeContentViewerInteraction())

        let symbols = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: symbols), for: .normal)
        menuButton.accessibilityLabel = "More"
        menuButton.accessibilityIdentifier = "galleryMenu"

        newTabButton.setImage(UIImage(systemName: "plus", withConfiguration: symbols.applying(UIImage.SymbolConfiguration(weight: .semibold))), for: .normal)
        newTabButton.accessibilityLabel = "New Tab"
        newTabButton.accessibilityIdentifier = "galleryNewTab"

        var done = UIButton.Configuration.plain()
        done.title = "Done"
        // Glass content draws text in the label color unless the button names its own.
        done.baseForegroundColor = Palette.accentOnGlass
        done.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .headline)
            return attributes
        }
        done.contentInsets = .init(top: 0, leading: Spacing.m, bottom: 0, trailing: Spacing.m)
        done.titleLineBreakMode = .byTruncatingTail
        doneButton.configuration = done
        doneButton.accessibilityIdentifier = "galleryDone"

        modeSwitch.isHidden = true

        // The glyphs are the label color (white on the always-dark gallery), so they read as
        // active on the dark glass; Done keeps the accent as the bar's one main action.
        for button in [menuButton, newTabButton] {
            button.tintColor = Palette.textPrimary
        }
        doneButton.tintColor = Palette.accentOnGlass
        for button in [menuButton, newTabButton, doneButton] {
            button.showsLargeContentViewer = true
            button.largeContentTitle = button.accessibilityLabel
            glass.contentView.addSubview(button)
        }
        glass.contentView.addSubview(modeSwitch)
        doneButton.largeContentTitle = "Done"
    }

    /// Puts the optional controls in or out of the row. Returns whether anything changed; the
    /// caller lays the bar out again (animated or not, `animateRowChange`).
    @discardableResult
    func setShown(menu: Bool, newTab: Bool, done: Bool) -> Bool {
        guard menu != showsMenu || newTab != showsNewTab || done != showsDone else { return false }
        showsMenu = menu
        showsNewTab = newTab
        showsDone = done
        return true
    }

    /// After `setShown`: a control leaving fades where it stands, then the others glide to the
    /// new centered row with a short spring as the capsule takes its new width (`layout` lays the
    /// bar out in its parent); one arriving fades in at its place. Without `animated`, or when
    /// `canAnimate` says a finger is on the gallery by the time the glide would start, everything
    /// lands at once. A newer change takes over from wherever the last one was.
    func animateRowChange(animated: Bool, canAnimate: @escaping () -> Bool, layout: @escaping () -> Void) {
        rowGeneration += 1
        let generation = rowGeneration
        let buttons: [(UIButton, Bool)] = [(menuButton, showsMenu), (newTabButton, showsNewTab), (doneButton, showsDone)]
        let land = {
            for (button, shown) in buttons {
                button.layer.removeAllAnimations()
                button.isHidden = !shown
                button.alpha = 1
            }
            layout()
        }
        guard animated, window != nil, !Motion.prefersCrossfade else { return land() }
        let leaving = buttons.filter { !$0.1 && !$0.0.isHidden }.map(\.0)
        // Arriving: hidden ones, and any caught fading out by the change before this one.
        let arriving = buttons.filter { $0.1 && ($0.0.isHidden || $0.0.alpha < 1) }.map(\.0)
        for button in arriving where button.isHidden {
            button.alpha = 0
            button.isHidden = false
        }
        Motion.animate(Motion.quick, changes: { for button in leaving { button.alpha = 0 } }, completion: { [weak self] in
            guard let self, generation == rowGeneration else { return }
            for button in leaving {
                button.isHidden = true
                button.alpha = 1
            }
        })
        // The glide starts as the fade is mostly done, so nothing slides under a fading glyph.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glideDelay) { [weak self] in
            guard let self, generation == rowGeneration else { return }
            guard canAnimate() else { return land() }
            Motion.animate(Motion.barGlide, changes: layout)
            Motion.animate(Motion.quick) { for button in arriving { button.alpha = 1 } }
        }
    }

    private var rowGeneration = 0

    private func isShown(_ button: UIButton) -> Bool {
        switch button {
        case menuButton: showsMenu
        case newTabButton: showsNewTab
        case doneButton: showsDone
        default: true
        }
    }

    private static let glideDelay: TimeInterval = 0.1

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The switch's side and counts. Returns whether its width may have changed.
    @discardableResult
    func setMode(isPrivate: Bool, regularCount: Int, privateCount: Int) -> Bool {
        let changed = modeSwitch.set(isPrivate: isPrivate, regularCount: regularCount, privateCount: privateCount)
        if changed { setNeedsLayout() }
        return changed
    }

    /// The controls in the row, in order, with their widths.
    private func row(fitting size: CGSize) -> [(UIView, CGFloat)] {
        var row: [(UIView, CGFloat)] = []
        let side = Metrics.tapTarget
        if showsMenu { row.append((menuButton, side)) }
        if showsPrivateButton { row.append((modeSwitch, modeSwitch.sizeThatFits(size).width)) }
        if showsNewTab { row.append((newTabButton, side)) }
        if showsDone {
            // At the largest text "Done" truncates rather than push the capsule off the screen.
            let done = min(max(side, doneButton.sizeThatFits(size).width), Self.maxDoneWidth)
            row.append((doneButton, done))
        }
        return row
    }

    /// The space between two controls: the glyphs' usual gap, closer beside the switch, whose
    /// capsule is its own edge.
    private func gap(_ a: UIView, _ b: UIView) -> CGFloat {
        a === modeSwitch || b === modeSwitch ? Spacing.s : Spacing.xl
    }

    private func width(of row: [(UIView, CGFloat)]) -> CGFloat {
        var width = Self.padding * 2 + row.reduce(0) { $0 + $1.1 }
        for index in row.indices.dropFirst() { width += gap(row[index - 1].0, row[index].0) }
        return width
    }

    /// Fits the bar into `width`: the switch drops its counts before the bar outgrows the screen
    /// (the Duo's outer screen, the largest text). Measured first; the switch changes only when
    /// the answer does. Returns the bar's size.
    func fit(width available: CGFloat) -> CGSize {
        let size = CGSize(width: available, height: Self.height)
        if showsPrivateButton {
            let counted = modeSwitch.fittingWidth(showingCounts: true)
            let withCounts = row(fitting: size).map { $0.0 === modeSwitch ? ($0.0, counted) : $0 }
            let fits = width(of: withCounts) <= available
            if modeSwitch.showsCounts != fits { modeSwitch.showsCounts = fits }
        }
        return sizeThatFits(size)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: max(width(of: row(fitting: size)), Self.height), height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let side = Metrics.tapTarget
        let y = ((bounds.height - side) / 2).rounded()
        var x = Self.padding
        var previous: UIView?
        for (view, width) in row(fitting: bounds.size) {
            if let previous { x += gap(previous, view) }
            view.frame = CGRect(x: x, y: y, width: width, height: side)
            x += width
            previous = view
        }
    }

    /// "Done" never takes more than this, in points.
    private static let maxDoneWidth: CGFloat = 120
}

/// The switcher's two lists as one two-state control, Safari's "Private | N Tabs": Private on the
/// leading side (Safari's order), each side named, with its count. The side shown sits on a
/// filled capsule: Horizon for Private, light for Tabs, so the mode reads from across the room and
/// the way back is the other word, one tap away (owner, 2026-11-27: "confusing how to turn off
/// private mode"; NN/g: name the modes, show the active one, keep the exit labelled).
///
/// The same control ends the tab strip on wide screens (`Style.strip`: the strip's height, on its
/// glass), so the phone's switcher and the inner screen's tab list enter and leave private the
/// same way (docs/decisions.md, "Private as a clear mode on wide screens").
final class GalleryModeSwitch: UIView {
    enum Style {
        /// The switcher's bar: always on dark glass.
        case gallery
        /// The end of the tab strip: on the strip's glass (Paper, or Night while private), as
        /// tall as a tab.
        case strip
    }

    let style: Style
    let privateSide = UIButton(type: .custom)
    let tabsSide = UIButton(type: .custom)
    private let thumb = UIView()
    private(set) var isPrivate = false
    private var counts = (regular: 0, private: 0)
    /// The counts show while the bar fits them (`GalleryBottomBar`); the words always do.
    var showsCounts = true {
        didSet { if showsCounts != oldValue { applyTitles() } }
    }
    /// A side was tapped: true for Private.
    var onSelect: (Bool) -> Void = { _ in }

    private var sideInset: CGFloat { style == .gallery ? 12 : 10 }
    private var minSide: CGFloat { style == .gallery ? 64 : 52 }
    private var textStyle: UIFont.TextStyle { style == .gallery ? .subheadline : .footnote }

    init(style: Style = .gallery) {
        self.style = style
        super.init(frame: .zero)
        // The bar's cap (AddressPill) would push the capsule off the Duo's outer screen; the Large
        // Content Viewer shows the words big.
        maximumContentSizeCategory = .extraLarge
        thumb.layer.cornerCurve = .continuous
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        for (button, isPrivateSide) in [(privateSide, true), (tabsSide, false)] {
            button.showsLargeContentViewer = true
            button.addAction(UIAction { [weak self] _ in self?.onSelect(isPrivateSide) }, for: .primaryActionTriggered)
            addSubview(button)
        }
        privateSide.accessibilityIdentifier = style == .gallery ? "galleryPrivate" : "tabStrip.private"
        privateSide.accessibilityLabel = String(localized: "Private")
        privateSide.largeContentTitle = String(localized: "Private")
        tabsSide.accessibilityIdentifier = style == .gallery ? "galleryRegular" : "tabStrip.regular"
        tabsSide.accessibilityLabel = String(localized: "Tabs")
        tabsSide.largeContentTitle = String(localized: "Tabs")
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) {
            (view: GalleryModeSwitch, _) in view.applyTitles()
        }
        applyTitles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Which side shows, and how many cards each list has. Changes nothing when nothing changed;
    /// returns whether the switch's width changed (a count gained a digit, or came or went).
    @discardableResult
    func set(isPrivate: Bool, regularCount: Int, privateCount: Int) -> Bool {
        guard isPrivate != self.isPrivate || regularCount != counts.regular || privateCount != counts.private else { return false }
        // The counted width too: while the counts are hidden, a shorter count may let them back.
        let before = (fittingWidth(showingCounts: showsCounts), fittingWidth(showingCounts: true))
        self.isPrivate = isPrivate
        counts = (regularCount, privateCount)
        applyTitles()
        setNeedsLayout()
        return (fittingWidth(showingCounts: showsCounts), fittingWidth(showingCounts: true)) != before
    }

    /// The text of a side: ink on the filled capsule (Horizon, or the light Tabs one), light on
    /// the gallery's dark glass, the glass's own secondary ink on the strip.
    private func textColor(selected: Bool, privateSide isPrivateSide: Bool) -> UIColor {
        if selected {
            if isPrivateSide { return Palette.privateSelectionInk }
            return style == .gallery ? Palette.galleryModeInk : Palette.textPrimary
        }
        return style == .gallery ? .white : Palette.textSecondary
    }

    private func title(privateSide isPrivateSide: Bool, showingCounts: Bool) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traitCollection)
        let selected = isPrivateSide == isPrivate
        let count = isPrivateSide ? counts.private : counts.regular
        let color = textColor(selected: selected, privateSide: isPrivateSide).resolvedColor(with: traitCollection)
        let title = NSMutableAttributedString(
            string: isPrivateSide ? String(localized: "Private") : String(localized: "Tabs"),
            attributes: [.font: font.withWeight(.semibold), .foregroundColor: color]
        )
        if showingCounts, count > 0 {
            let digits = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            title.append(NSAttributedString(
                string: " \(count)", attributes: [.font: digits, .foregroundColor: color.withAlphaComponent(0.72)]
            ))
        }
        return title
    }

    private func applyTitles() {
        for (button, isPrivateSide) in [(privateSide, true), (tabsSide, false)] {
            let count = isPrivateSide ? counts.private : counts.regular
            button.setAttributedTitle(title(privateSide: isPrivateSide, showingCounts: showsCounts), for: .normal)
            button.accessibilityValue = count == 1 ? String(localized: "1 tab") : String(localized: "\(count) tabs")
            button.accessibilityTraits = isPrivateSide == isPrivate ? [.button, .selected] : .button
        }
        switch style {
        case .gallery:
            thumb.backgroundColor = isPrivate ? Palette.privateSelection : Palette.galleryModeLight
        case .strip:
            // Tabs: a solid card with a hairline, as the tab on screen, but a capsule, so it never
            // reads as one more tab.
            thumb.backgroundColor = isPrivate ? Palette.privateSelection : Palette.surface
            thumb.layer.borderWidth = isPrivate ? 0 : 0.5
            thumb.layer.borderColor = Palette.tabPlateEdge.resolvedColor(with: traitCollection).cgColor
        }
    }

    private func sideWidth(_ title: NSAttributedString) -> CGFloat {
        max(minSide, ceil(title.size().width) + sideInset * 2)
    }

    private func sideWidth(_ button: UIButton) -> CGFloat {
        sideWidth(button.attributedTitle(for: .normal) ?? NSAttributedString())
    }

    /// The switch's width with or without the counts, measured without changing what it shows.
    func fittingWidth(showingCounts: Bool) -> CGFloat {
        sideWidth(title(privateSide: true, showingCounts: showingCounts))
            + sideWidth(title(privateSide: false, showingCounts: showingCounts))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: sideWidth(privateSide) + sideWidth(tabsSide), height: Metrics.tapTarget)
    }

    /// The filled capsule's height: the gallery's bar less a hair, or a strip tab's.
    private var thumbHeight: CGFloat { style == .gallery ? Metrics.tapTarget - 2 * Spacing.xxs : 30 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let privateWidth = sideWidth(privateSide)
        // Private leads: on the right in a right-to-left language.
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let tabsWidth = max(0, bounds.width - privateWidth)
        privateSide.frame = CGRect(x: rightToLeft ? tabsWidth : 0, y: 0, width: privateWidth, height: bounds.height)
        tabsSide.frame = CGRect(x: rightToLeft ? 0 : privateWidth, y: 0, width: tabsWidth, height: bounds.height)
        let selected = isPrivate ? privateSide.frame : tabsSide.frame
        let thumbFrame = selected.insetBy(dx: 0, dy: max(0, (bounds.height - thumbHeight) / 2))
        if thumb.frame != thumbFrame { thumb.frame = thumbFrame }
        thumb.layer.cornerRadius = thumbFrame.height / 2
    }
}

/// "Reopen Tab", shown only after a close and gone a few seconds later (docs/ui-reference.md).
final class ReopenToast: UIView {
    let button = UIButton(type: .system)
    private let glass = Glass.makeView(shape: .capsule, interactive: true, tint: Palette.glassTintOnPaper)
    private var hideTask: Task<Void, Never>?
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Reopen Tab"
        configuration.image = UIImage(systemName: "arrow.uturn.backward")
        configuration.imagePadding = Spacing.s
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return attributes
        }
        configuration.contentInsets = .init(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l)
        configuration.baseForegroundColor = Palette.accentOnGlass
        button.configuration = configuration
        button.tintColor = Palette.accentOnGlass
        button.accessibilityIdentifier = "reopenTab"
        glass.contentView.addSubview(button)
        alpha = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = button.sizeThatFits(size)
        return CGSize(width: ceil(fit.width), height: Metrics.tapTarget)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = bounds
    }

    /// Shows the toast, or keeps it up a little longer after another close.
    func show(animated: Bool) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TabGalleryChoices.reopenToastDuration))
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
        guard !isShowing else { return }
        isShowing = true
        isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "Tab closed")
        if animated, !Motion.prefersCrossfade { transform = CGAffineTransform(translationX: 0, y: 12) }
        let changes = {
            self.alpha = 1
            self.transform = .identity
        }
        if animated {
            Motion.animate(Motion.reflow, changes: changes)
        } else {
            changes()
        }
    }

    func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        guard isShowing else { return }
        isShowing = false
        let finish = { [weak self] in
            guard let self, !isShowing else { return }
            isHidden = true
        }
        guard animated else {
            alpha = 0
            finish()
            return
        }
        Motion.animate(Motion.quick, changes: {
            self.alpha = 0
            if !Motion.prefersCrossfade { self.transform = CGAffineTransform(translationX: 0, y: 8) }
        }, completion: finish)
    }
}

/// Shown only when the gallery opens with no tabs. After the last tab closes, the shell goes
/// straight to the search field instead (docs/ui-reference.md).
final class GalleryEmptyView: UIView {
    let label = UILabel()
    let button = UIButton(type: .system)
    /// The mark, as on the start screen: a finger can spin it, so the screen is never dead.
    let mark = MarkView()
    private static let markSide: CGFloat = 88

    override init(frame: CGRect) {
        super.init(frame: frame)
        mark.isSpinnable = true
        addSubview(mark)
        label.text = "Your open tabs show up here."
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Palette.textSecondary
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "New Tab"
        configuration.baseBackgroundColor = Palette.accent
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: Spacing.m, leading: Spacing.xl, bottom: Spacing.m, trailing: Spacing.xl)
        button.configuration = configuration
        button.accessibilityIdentifier = "emptyNewTab"
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The sentence and button for regular or private tabs.
    func setPrivate(_ isPrivate: Bool) {
        label.text = isPrivate
            ? "Private tabs show up here, and Plain keeps no history of them."
            : "Your open tabs show up here."
        button.configuration?.title = isPrivate ? "New Private Tab" : "New Tab"
        setNeedsLayout()
    }

    /// The regular list's sentence: the data source's (a profile with no tabs yet), else the
    /// default.
    @discardableResult
    func setText(_ text: String?) -> Bool {
        let text = text ?? "Your open tabs show up here."
        guard label.text != text else { return false }
        label.text = text
        setNeedsLayout()
        return true
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude))
        let buttonSize = button.sizeThatFits(size)
        return CGSize(
            width: size.width,
            height: Self.markSide + Spacing.xl + ceil(text.height) + Spacing.l + max(Metrics.tapTarget, buttonSize.height)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        mark.frame = CGRect(x: ((bounds.width - Self.markSide) / 2).rounded(), y: 0, width: Self.markSide, height: Self.markSide)
        label.frame = CGRect(x: 0, y: mark.frame.maxY + Spacing.xl, width: bounds.width, height: ceil(text.height))
        let size = button.sizeThatFits(bounds.size)
        let height = max(Metrics.tapTarget, size.height)
        button.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: label.frame.maxY + Spacing.l, width: size.width, height: height)
    }
}

extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
