#if canImport(UIKit)
import BrowserCore
import DesignSystem
import UIKit

/// What a row or tile in the search sheet opens.
enum SearchPick {
    case page(URL)
    case search(String)
}

/// The search sheet the URL pill grows into: it covers the page, lists suggestions above the field,
/// and shows favorites directly above it (and so above the keyboard) while the field is empty.
///
/// Rows are made once and reused, so a keystroke only sets text; there is no table to reload.
/// The best suggestion sits nearest the field, where the thumb is.
final class SearchSheet: UIView, UIGestureRecognizerDelegate {
    /// The sheet's content. The owner pins its bottom above the pill and its sides to the margins.
    let content = UIView()
    var onPick: (SearchPick) -> Void = { _ in }
    /// A tap on the sheet outside any row: close the sheet.
    var onDismiss: () -> Void = {}

    private let rowsClip = UIView()
    private let rowsStack = UIStackView()
    private var rows: [SuggestionRow] = []
    private let favoritesStrip = FavoritesStrip()
    private var favoritesHeight: NSLayoutConstraint!
    private var showsFavorites = false
    private var hasFavorites = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.background
        accessibilityIdentifier = "searchSheet"

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        rowsClip.clipsToBounds = true
        rowsClip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rowsClip)

        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsClip.addSubview(rowsStack)
        for index in 0..<FixedChoices.maxAddressBarSuggestions {
            let row = SuggestionRow()
            row.isHidden = true
            row.addAction(UIAction { [weak self, weak row] _ in
                guard let self, let pick = row?.pick else { return }
                self.onPick(pick)
            }, for: .touchUpInside)
            row.tag = index
            rows.append(row)
            rowsStack.addArrangedSubview(row)
        }

        favoritesStrip.onPick = { [weak self] url in self?.onPick(.page(url)) }
        favoritesStrip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(favoritesStrip)
        favoritesHeight = favoritesStrip.heightAnchor.constraint(equalToConstant: 0)

        // The stack hangs from the bottom; rows that do not fit leave at the top.
        let stackTop = rowsStack.topAnchor.constraint(greaterThanOrEqualTo: rowsClip.topAnchor)
        stackTop.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rowsClip.topAnchor.constraint(equalTo: content.topAnchor),
            rowsClip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rowsClip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rowsClip.bottomAnchor.constraint(equalTo: favoritesStrip.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: rowsClip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsClip.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: rowsClip.bottomAnchor),
            stackTop,
            favoritesStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            favoritesStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            favoritesStrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            favoritesHeight,
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only whole rows show: one that would be cut by the top edge fades out instead.
        rowsClip.layoutIfNeeded()
        for row in rows where !row.isHidden {
            let top = row.convert(row.bounds, to: rowsClip).minY
            row.alpha = top < -0.5 ? 0 : 1
        }
    }

    /// Shows `suggestions`, best first, the first one nearest the field.
    func show(_ suggestions: [AddressBarSuggestion]) {
        let shown = Array(suggestions.prefix(rows.count))
        let firstVisible = rows.count - shown.count
        // Rows run top to bottom, so the best one (index 0) goes in the last slot.
        for (slot, row) in rows.enumerated() {
            if slot >= firstVisible {
                let index = rows.count - 1 - slot
                row.configure(shown[index], index: index)
                row.isHidden = false
            } else {
                row.isHidden = true
                row.pick = nil
            }
        }
        // VoiceOver reads best first.
        rowsStack.accessibilityElements = rows.filter { !$0.isHidden }.reversed()
        updateFavoritesVisibility()
        // Re-check which rows fit (layoutSubviews) once the stack has its new rows.
        setNeedsLayout()
    }

    /// Whether the favorites strip may show: only while the field is empty.
    func setFavoritesAllowed(_ allowed: Bool) {
        showsFavorites = allowed
        updateFavoritesVisibility()
    }

    func setFavorites(_ favorites: [FavoritePage]) {
        favoritesStrip.show(favorites)
        hasFavorites = !favorites.isEmpty
        updateFavoritesVisibility()
    }

    private func updateFavoritesVisibility() {
        let visible = showsFavorites && hasFavorites
        favoritesStrip.isHidden = !visible
        favoritesHeight.constant = visible ? FavoritesStrip.height : 0
    }

    @objc private func backgroundTapped() {
        onDismiss()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Only taps on empty sheet, not on rows or tiles.
        var view = touch.view
        while let current = view, current !== self {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }
}

/// One suggestion: a page (from history or favorites) or a search from the engine.
final class SuggestionRow: UIControl {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    var pick: SearchPick?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = Radius.large
        layer.cornerCurve = .continuous

        icon.tintColor = Palette.textSecondary
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Palette.textPrimary
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Palette.textSecondary
        detail.lineBreakMode = .byTruncatingMiddle

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = Spacing.xxs
        text.isUserInteractionEnabled = false
        for view in [icon, text] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.rowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Spacing.m),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.m),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Spacing.s),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Spacing.s),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Palette.pressed : nil }
    }

    func configure(_ suggestion: AddressBarSuggestion, index: Int) {
        switch suggestion {
        case .page(let url, let pageTitle, let isFavorite):
            let address = Self.displayAddress(url)
            let name = pageTitle.flatMap { $0.isEmpty ? nil : $0 }
            title.text = name ?? address
            detail.text = name == nil ? nil : address
            detail.isHidden = name == nil
            icon.image = UIImage(systemName: isFavorite ? "star" : "clock")
            pick = .page(url)
            accessibilityIdentifier = "suggestion.page.\(index)"
            accessibilityLabel = title.text
            accessibilityValue = detail.text
        case .search(let query):
            title.text = query
            detail.text = nil
            detail.isHidden = true
            icon.image = UIImage(systemName: "magnifyingglass")
            pick = .search(query)
            accessibilityIdentifier = "suggestion.search.\(index)"
            accessibilityLabel = query
            accessibilityValue = nil
        }
    }

    /// An address as people read it: host without `www.`, then the path, no scheme.
    static func displayAddress(_ url: URL) -> String {
        guard var host = url.host() else { return url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = url.port { host += ":\(port)" }
        let path = url.path()
        return path.isEmpty || path == "/" ? host : host + path
    }
}

/// Favorites above the keyboard: a row of tiles that scrolls sideways when there are many.
final class FavoritesStrip: UIView {
    static let height: CGFloat = 88
    var onPick: (URL) -> Void = { _ in }
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.s),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -Spacing.s),
        ])
        accessibilityIdentifier = "favorites"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ favorites: [FavoritePage]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, favorite) in favorites.enumerated() {
            let tile = FavoriteTile(favorite)
            tile.accessibilityIdentifier = "favorite.\(index)"
            tile.addAction(UIAction { [weak self] _ in self?.onPick(favorite.url) }, for: .touchUpInside)
            stack.addArrangedSubview(tile)
        }
    }
}

/// A favorite: a monogram disc and its name.
final class FavoriteTile: UIControl {
    private let disc = UIView()

    init(_ favorite: FavoritePage) {
        super.init(frame: .zero)
        let name = FavoriteTile.name(for: favorite)
        disc.backgroundColor = Palette.surface
        disc.layer.cornerRadius = Metrics.favoriteTile / 2
        disc.layer.cornerCurve = .continuous
        let letter = UILabel()
        letter.text = name.first.map { String($0).uppercased() }
        letter.font = .systemFont(ofSize: 22, weight: .semibold)
        letter.textColor = Palette.accent
        letter.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(letter)
        let caption = UILabel()
        caption.text = name
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = Palette.textPrimary
        caption.textAlignment = .center
        caption.lineBreakMode = .byTruncatingTail
        for view in [disc, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 68),
            disc.topAnchor.constraint(equalTo: topAnchor),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.widthAnchor.constraint(equalToConstant: Metrics.favoriteTile),
            disc.heightAnchor.constraint(equalToConstant: Metrics.favoriteTile),
            letter.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            caption.topAnchor.constraint(equalTo: disc.bottomAnchor, constant: Spacing.xs),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { disc.backgroundColor = isHighlighted ? Palette.pressed : Palette.surface }
    }

    static func name(for favorite: FavoritePage) -> String {
        if let title = favorite.title, !title.isEmpty { return title }
        guard var host = favorite.url.host() else { return favorite.url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
#endif
