#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit

/// What the page sheet shows (docs/decisions.md, "Address focus and the page sheet"), built by
/// the shell from the same actions the page menu had, so every item keeps its rule, title and
/// identifier. Only what applies now is in it (state rules §4).
struct PageSheetModel {
    /// The address row: Back, Forward, the host (a tap edits the address), Copy Link, Reload.
    struct Address {
        var host: String
        var notSecure: Bool
        var back: UIAction?
        var forward: UIAction?
        var copy: UIAction
        var reload: UIAction?
    }

    enum Row {
        /// One action, full width. `stays` keeps the sheet open (it answers in place).
        case action(UIAction, stays: Bool = false)
        /// A row that opens a menu (Site Settings).
        case menu(UIMenu)
        /// Small captioned buttons in one card (the tabs' places, the app's places).
        case chips([UIMenuElement])
        /// Zoom: − percentage +, acting in place.
        case stepper([UIAction])
    }

    var address: Address?
    /// Big captioned tiles for the most used page actions, at most four.
    var tiles: [UIAction] = []
    var rows: [Row] = []
}

/// The page sheet: the page's address and what can be done with it, over the page (Arc's page
/// sheet, in Plain's paper). A bottom sheet sized to its content on narrow screens, a popover
/// under More on the Duo's inner screen.
final class PageSheetController: UIViewController {
    /// Builds the model again (after a zoom step, or when the page changes under it).
    private let build: () -> PageSheetModel
    /// The host was tapped: the field takes the page's address.
    var onEditAddress: () -> Void = {}
    /// The sheet is gone, by a choice or a swipe (the shell's sheet lifecycle: a waiting toast
    /// shows then).
    var onDismissed: () -> Void = {}
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var copyToken = 0
    private weak var copyButton: UIButton?

    init(build: @escaping () -> PageSheetModel) {
        self.build = build
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismissed() }
    }

    /// `menu` with every choice closing the sheet first: a toggle's title was captured when the
    /// sheet opened, so choosing it twice from one open sheet would repeat it.
    private func dismissing(_ menu: UIMenu) -> UIMenu {
        menu.replacingChildren(menu.children.map { element in
            if let submenu = element as? UIMenu { return dismissing(submenu) }
            guard let action = element as? UIAction else { return element }
            let wrapped = UIAction(
                title: action.title, subtitle: action.subtitle, image: action.image,
                attributes: action.attributes, state: action.state
            ) { [weak self] _ in
                guard let self else { return action.performWithSender(nil, target: nil) }
                self.dismiss(animated: true) { action.performWithSender(nil, target: nil) }
            }
            wrapped.accessibilityIdentifier = action.accessibilityIdentifier
            wrapped.accessibilityLabel = action.accessibilityLabel
            return wrapped
        })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Paper.apply(to: view)
        view.accessibilityIdentifier = "pageSheet"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let guide = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: Spacing.xl),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Spacing.l),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.l),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.l),
        ])
        reload()
    }

    /// The content's height at `width`: the sheet's detent and the popover's size.
    func fittingHeight(width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let size = stack.systemLayoutSizeFitting(
            CGSize(width: width - 2 * Spacing.l, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(size.height + Spacing.xl + Spacing.l)
    }

    /// Rebuilds the content from the shell's current state, without animation: it changes only
    /// after a tap that acts in place (zoom), where the new value is the answer.
    func reload() {
        let model = build()
        UIView.performWithoutAnimation {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if let address = model.address { stack.addArrangedSubview(addressRow(address)) }
            if !model.tiles.isEmpty { stack.addArrangedSubview(tilesRow(model.tiles)) }
            for row in model.rows { stack.addArrangedSubview(view(for: row)) }
            view.layoutIfNeeded()
        }
        let width = view.bounds.width > 0 ? view.bounds.width : 360
        preferredContentSize = CGSize(width: 360, height: fittingHeight(width: width))
    }

    // MARK: Pieces

    private func addressRow(_ address: PageSheetModel.Address) -> UIView {
        let card = Self.card()
        card.layer.cornerRadius = Metrics.rowHeight / 2
        var items: [UIView] = []
        for action in [address.back, address.forward] {
            guard let action else { continue }
            items.append(iconButton(action, dismisses: true))
        }
        var host = UIButton.Configuration.plain()
        host.attributedTitle = AttributedString(address.host, attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .headline), .foregroundColor: Palette.ink,
        ]))
        if address.notSecure {
            host.subtitle = String(localized: "Not Secure")
            host.titleAlignment = .center
        }
        host.titleLineBreakMode = .byTruncatingHead
        let hostButton = UIButton(configuration: host, primaryAction: UIAction { [weak self] _ in
            self?.onEditAddress()
        })
        hostButton.accessibilityIdentifier = "pageSheet.address"
        hostButton.accessibilityLabel = address.host
        hostButton.accessibilityHint = String(localized: "Edits the address")
        hostButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        items.append(hostButton)
        let copy = iconButton(address.copy, dismisses: false, reloads: false)
        copy.addAction(UIAction { [weak self] _ in self?.showCopied() }, for: .touchUpInside)
        copyButton = copy
        items.append(copy)
        if let reload = address.reload { items.append(iconButton(reload, dismisses: true)) }
        let row = UIStackView(arrangedSubviews: items)
        row.alignment = .center
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rowHeight),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Spacing.xs),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Spacing.xs),
        ])
        return card
    }

    private func tilesRow(_ actions: [UIAction]) -> UIView {
        let row = UIStackView(arrangedSubviews: actions.map { tile($0) })
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = Spacing.s
        return row
    }

    /// A tile: the symbol on a card, the caption under it.
    private func tile(_ action: UIAction) -> UIView {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Palette.paperCard
        configuration.baseForegroundColor = Palette.ink
        configuration.background.cornerRadius = Radius.large
        configuration.background.strokeColor = Palette.paperHairline
        configuration.background.strokeWidth = 1 / max(1, traitCollection.displayScale)
        configuration.image = action.image
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title2)
        configuration.imagePlacement = .top
        configuration.imagePadding = Spacing.s
        configuration.attributedTitle = AttributedString(Self.caption(action.title), attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: Palette.inkSecondary,
        ]))
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: Spacing.m, leading: Spacing.xs, bottom: Spacing.s, trailing: Spacing.xs)
        let button = UIButton(configuration: configuration, primaryAction: perform(action, dismisses: true))
        Self.identify(button, as: action)
        button.isEnabled = !action.attributes.contains(.disabled)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        return button
    }

    private func view(for row: PageSheetModel.Row) -> UIView {
        switch row {
        case .action(let action, let stays):
            let button = rowButton(title: action.title, subtitle: action.subtitle, image: action.image, chevron: false)
            button.addAction(perform(action, dismisses: !stays), for: .primaryActionTriggered)
            Self.identify(button, as: action)
            button.isEnabled = !action.attributes.contains(.disabled)
            if action.attributes.contains(.destructive) { button.configuration?.baseForegroundColor = .systemRed }
            return button
        case .menu(let menu):
            let button = rowButton(title: menu.title, subtitle: menu.subtitle, image: menu.image, chevron: true)
            // A choice closes the sheet: the next opening reads the new value (a toggle never repeats).
            button.menu = dismissing(menu)
            button.showsMenuAsPrimaryAction = true
            button.accessibilityIdentifier = menu.accessibilityIdentifier
            button.accessibilityLabel = [menu.title, menu.subtitle].compactMap { $0 }.joined(separator: ", ")
            return button
        case .chips(let actions):
            let card = Self.card()
            let row = UIStackView(arrangedSubviews: actions.map { chip($0) })
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            Self.pin(row, in: card, inset: Spacing.xs)
            return card
        case .stepper(let actions):
            let card = Self.card()
            let row = UIStackView(arrangedSubviews: actions.map { action in
                let button = UIButton(configuration: .plain(), primaryAction: perform(action, dismisses: false))
                if action.image == nil {
                    button.configuration?.attributedTitle = AttributedString(action.title, attributes: AttributeContainer([
                        .font: UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium),
                    ]))
                } else {
                    button.configuration?.image = action.image
                    button.accessibilityLabel = action.title
                }
                button.configuration?.baseForegroundColor = Palette.ink
                button.isEnabled = !action.attributes.contains(.disabled)
                Self.identify(button, as: action)
                return button
            })
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(row)
            Self.pin(row, in: card, inset: 0)
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tapTarget + Spacing.xs).isActive = true
            return card
        }
    }

    private func rowButton(title: String, subtitle: String?, image: UIImage?, chevron: Bool) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Palette.paperCard
        configuration.baseForegroundColor = Palette.ink
        configuration.background.cornerRadius = Radius.large
        configuration.background.strokeColor = Palette.paperHairline
        configuration.background.strokeWidth = 1 / max(1, traitCollection.displayScale)
        configuration.image = image
        configuration.imagePadding = Spacing.m
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: Palette.ink,
        ]))
        if let subtitle {
            configuration.attributedSubtitle = AttributedString(subtitle, attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: Palette.inkSecondary,
            ]))
        }
        configuration.titleAlignment = .leading
        configuration.contentInsets = NSDirectionalEdgeInsets(top: Spacing.m, leading: Spacing.l, bottom: Spacing.m, trailing: Spacing.l)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.tapTarget + Spacing.xs).isActive = true
        if chevron {
            let mark = UIImageView(image: UIImage(systemName: "chevron.right"))
            mark.tintColor = Palette.inkSecondary
            mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
            mark.translatesAutoresizingMaskIntoConstraints = false
            mark.isUserInteractionEnabled = false
            button.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Spacing.l),
                mark.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
        }
        return button
    }

    /// A small captioned button inside a card (History, Favorites, Settings; the tabs' places).
    private func chip(_ element: UIMenuElement) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = element.image
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        configuration.imagePlacement = .top
        configuration.imagePadding = Spacing.xs
        configuration.baseForegroundColor = Palette.ink
        configuration.attributedTitle = AttributedString(Self.caption(element.title), attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: Palette.inkSecondary,
        ]))
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: Spacing.s, leading: Spacing.xxs, bottom: Spacing.s, trailing: Spacing.xxs)
        let button = UIButton(configuration: configuration)
        if let menu = element as? UIMenu {
            // A chip that opens a menu (Site Settings); a choice there closes the sheet.
            button.menu = dismissing(menu)
            button.showsMenuAsPrimaryAction = true
            button.accessibilityIdentifier = menu.accessibilityIdentifier
            button.accessibilityLabel = [menu.title, menu.subtitle].compactMap { $0 }.joined(separator: ", ")
        } else if let action = element as? UIAction {
            button.addAction(perform(action, dismisses: true), for: .primaryActionTriggered)
            Self.identify(button, as: action)
            button.isEnabled = !action.attributes.contains(.disabled)
        }
        return button
    }

    private func iconButton(_ action: UIAction, dismisses: Bool, reloads: Bool = true) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = action.image
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        configuration.baseForegroundColor = Palette.ink
        let button = UIButton(configuration: configuration, primaryAction: perform(action, dismisses: dismisses, reloads: reloads))
        Self.identify(button, as: action)
        button.isEnabled = !action.attributes.contains(.disabled)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            button.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
        ])
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// Copy Link answers in place: a check mark for a moment.
    private func showCopied() {
        copyToken += 1
        let token = copyToken
        copyButton?.configuration?.image = UIImage(systemName: "checkmark")
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + FixedChoices.copiedConfirmation) { [weak self] in
            guard let self, self.copyToken == token else { return }
            self.copyButton?.configuration?.image = UIImage(systemName: "link")
        }
    }

    /// Runs `action`: after the sheet has gone for actions that lead elsewhere (a sheet, the find
    /// bar, another page), at once for ones that answer in place.
    private func perform(_ action: UIAction, dismisses: Bool, reloads: Bool = true) -> UIAction {
        UIAction { [weak self] _ in
            guard let self else { return }
            guard dismisses else {
                action.performWithSender(nil, target: nil)
                // The new value is the answer (zoom's percentage).
                if reloads { self.reload() }
                return
            }
            self.dismiss(animated: true) { action.performWithSender(nil, target: nil) }
        }
    }

    private static func card() -> UIView {
        let card = UIView()
        card.backgroundColor = Palette.paperCard
        card.layer.cornerRadius = Radius.large
        card.layer.cornerCurve = .continuous
        card.layer.borderColor = Palette.paperHairline.cgColor
        card.layer.borderWidth = 0.5
        return card
    }

    private static func pin(_ view: UIView, in card: UIView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
        ])
    }

    /// The short caption a tile or chip shows; VoiceOver keeps the full name.
    private static func caption(_ title: String) -> String {
        let captions = [
            "Find on Page": String(localized: "Find"), "Translate Page": String(localized: "Translate"),
            "Show Original": String(localized: "Original"), "Show Reader": String(localized: "Reader"),
            "Hide Reader": String(localized: "Reader"),
            "New Private Tab": String(localized: "Private Tab"), "Reopen Closed Tab": String(localized: "Reopen Tab"),
            "Archived Tabs": String(localized: "Archive"), "Add to Favorites": String(localized: "Favorite"),
            "Remove from Favorites": String(localized: "Unfavorite"), "Edit Favorites": String(localized: "Favorites"),
            "Remove from Reading List": String(localized: "Remove"),
        ]
        return captions[title] ?? title
    }

    private static func identify(_ button: UIButton, as action: UIAction) {
        button.accessibilityIdentifier = action.accessibilityIdentifier
        button.accessibilityLabel = action.accessibilityLabel
            ?? [action.title, action.subtitle].compactMap { $0 }.joined(separator: ", ")
    }
}
#endif
