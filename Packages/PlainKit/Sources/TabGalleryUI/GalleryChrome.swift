#if canImport(UIKit)
import DesignSystem
import UIKit

/// The gallery's floating bar: the gallery menu, the private toggle, New Tab and Done, on one
/// glass capsule. A control the state rules leave out is taken out of the row and the capsule
/// fits the rest, centered (UX audit, 2026-11-27: a hidden-in-place More left the row
/// off-centre). Text is capped at the pill's size; a long press shows the Large Content Viewer.
final class GalleryBottomBar: UIView {
    let menuButton = UIButton(type: .system)
    let privateButton = UIButton(type: .system)
    let newTabButton = UIButton(type: .system)
    let doneButton = UIButton(type: .system)
    /// Whether the private toggle shows (the data source supports private tabs).
    var showsPrivateButton = false {
        didSet {
            privateButton.isHidden = !showsPrivateButton
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

        privateButton.accessibilityLabel = "Private"
        privateButton.accessibilityIdentifier = "galleryPrivate"
        privateButton.isHidden = true
        setPrivate(false)

        // The glyphs are the label color (white on the always-dark gallery), so they read as
        // active on the dark glass; Done keeps the accent as the bar's one main action.
        for button in [menuButton, privateButton, newTabButton] {
            button.tintColor = Palette.textPrimary
        }
        doneButton.tintColor = Palette.accentOnGlass
        for button in [menuButton, privateButton, newTabButton, doneButton] {
            button.showsLargeContentViewer = true
            button.largeContentTitle = button.accessibilityLabel
            glass.contentView.addSubview(button)
        }
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
    /// bar out in its parent); one arriving fades in at its place. Without `animated` everything
    /// lands at once. Never called mid-gesture: the gallery waits until the bar is at rest.
    func animateRowChange(animated: Bool, layout: @escaping () -> Void) {
        let buttons: [(UIButton, Bool)] = [(menuButton, showsMenu), (newTabButton, showsNewTab), (doneButton, showsDone)]
        guard animated, window != nil, !Motion.prefersCrossfade else {
            for (button, shown) in buttons {
                button.isHidden = !shown
                button.alpha = 1
            }
            layout()
            return
        }
        let leaving = buttons.filter { !$0.1 && !$0.0.isHidden }.map(\.0)
        let arriving = buttons.filter { $0.1 && $0.0.isHidden }.map(\.0)
        for button in arriving {
            button.alpha = 0
            button.isHidden = false
        }
        Motion.animate(Motion.quick, changes: { for button in leaving { button.alpha = 0 } }, completion: { [weak self] in
            guard let self else { return }
            for button in leaving where !self.isShown(button) { button.isHidden = true; button.alpha = 1 }
        })
        // The glide starts as the fade is mostly done, so nothing slides under a fading glyph.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glideDelay) {
            Motion.animate(Motion.barGlide, changes: layout)
            Motion.animate(Motion.quick) { for button in arriving { button.alpha = 1 } }
        }
    }

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

    /// The private toggle's look: on, a filled hand on a light disc (the selected state, as a
    /// selected bar button in the system's glass bars); off, the hand's outline like its
    /// neighbours (UX audit, 2026-11-27: the two looked alike).
    func setPrivate(_ isPrivate: Bool) {
        let symbols = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        var configuration = isPrivate ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: isPrivate ? "hand.raised.fill" : "hand.raised", withConfiguration: symbols)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        if isPrivate {
            configuration.baseBackgroundColor = Palette.textPrimary
            configuration.baseForegroundColor = Palette.privateBackground
        } else {
            configuration.baseForegroundColor = Palette.textPrimary
        }
        privateButton.configuration = configuration
        privateButton.accessibilityValue = isPrivate ? "On" : "Off"
        privateButton.accessibilityTraits = isPrivate ? [.button, .selected] : .button
    }

    /// The controls in the row, in order, with their widths.
    private func row(fitting size: CGSize) -> [(UIButton, CGFloat)] {
        var row: [(UIButton, CGFloat)] = []
        let side = Metrics.tapTarget
        if showsMenu { row.append((menuButton, side)) }
        if showsPrivateButton { row.append((privateButton, side)) }
        if showsNewTab { row.append((newTabButton, side)) }
        if showsDone {
            // At the largest text "Done" truncates rather than push the capsule off the screen.
            let done = min(max(side, doneButton.sizeThatFits(size).width), Self.maxDoneWidth)
            row.append((doneButton, done))
        }
        return row
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let row = row(fitting: size)
        let width = Self.padding * 2 + row.reduce(0) { $0 + $1.1 } + Spacing.xl * CGFloat(max(0, row.count - 1))
        return CGSize(width: max(width, Self.height), height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let side = Metrics.tapTarget
        let y = ((bounds.height - side) / 2).rounded()
        var x = Self.padding
        for (button, width) in row(fitting: bounds.size) {
            button.frame = CGRect(x: x, y: y, width: width, height: side)
            x += width + Spacing.xl
        }
    }

    /// "Done" never takes more than this, in points.
    private static let maxDoneWidth: CGFloat = 120
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
