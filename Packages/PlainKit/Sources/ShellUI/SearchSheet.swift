#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit

/// What a row or tile in the search sheet opens.
enum SearchPick {
    case page(URL)
    case search(String)
}

/// The search sheet the URL pill grows into: it covers the page, lists suggestions above the field,
/// and shows favorites directly above it (and so above the keyboard) while the field is empty.
///
/// The best suggestion sits nearest the field, where the thumb is.
///
/// Typing changes the list on every keystroke, so it changes calmly (docs/plan.md, motion table,
/// "Suggestions change"):
/// - Each row belongs to one suggestion (a page's address or a search's text). A suggestion that
///   stays in its place keeps its row untouched, so its text and icon never blink.
/// - Nothing slides while typing: a new suggestion fades in where it lands, one that goes fades
///   out where it stood, and one that changes place crossfades there. Every place on screen only
///   ever crossfades from one text to the next.
/// - Lists that arrive in the same run loop turn are applied once, the latest, just before Core
///   Animation commits, so the first list for a keystroke still shows on the next frame.
/// - Every change starts from what is on screen, so a keystroke mid-animation retargets it.
/// - Reduce Motion: the whole list crossfades at once.
final class SearchSheet: UIView, UIGestureRecognizerDelegate {
    /// The sheet's content. The owner pins its bottom above the pill and its sides to the margins.
    let content = UIView()
    var onPick: (SearchPick) -> Void = { _ in }
    /// A tap on the sheet outside any row: close the sheet.
    var onDismiss: () -> Void = {}
    /// "Edit Favorites" from a long press on the favorites strip.
    var onEditFavorites: () -> Void = {} {
        didSet { favoritesStrip.onEdit = onEditFavorites }
    }

    private let rowsClip = PassThroughView()
    /// The paper behind the rows, so they read over the start screen's mark even while it
    /// recedes (docs/state-rules.md §6, start screen while typing). It covers the whole sheet, so
    /// its texture lines up with the sheet's own paper, and a mask shows it only behind the rows.
    private let plate = UIView()
    private let plateMask = UIView()
    private let rowsStack = UIStackView()
    private var rowsBottom: NSLayoutConstraint!
    /// The rows on screen, best first.
    private var shownRows: [SuggestionRow] = []
    /// Rows fading out where they stood, outside the stack.
    private var leavingRows: [SuggestionRow] = []
    /// Rows ready for reuse.
    private var spareRows: [SuggestionRow] = []
    /// The list waiting for the end of this run loop turn, and the observer that applies it.
    private var pending: [AddressBarSuggestion]?
    private var flushObserver: CFRunLoopObserver?
    private var current: [AddressBarSuggestion] = []
    private let favoritesStrip = FavoritesStrip()
    private var showsFavorites = false
    private var hasFavorites = false
    private var favoritesShown = false
    private var favoritesToken = 0
    /// True while `update` lays out, so `layoutSubviews` leaves the rows to it.
    private var isApplying = false
    private var isToppingUp = false
    private var didWarmRows = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        Paper.apply(to: self)
        accessibilityIdentifier = "searchSheet"

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // Under the rows: the favorites sit where the first rows would, and only one of them
        // shows at a time (favorites for an empty field, rows for a query).
        favoritesStrip.onPick = { [weak self] url in self?.onPick(.page(url)) }
        favoritesStrip.translatesAutoresizingMaskIntoConstraints = false
        favoritesStrip.isHidden = true
        favoritesStrip.alpha = 0
        content.addSubview(favoritesStrip)

        rowsClip.clipsToBounds = true
        rowsClip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rowsClip)

        plate.isUserInteractionEnabled = false
        plate.alpha = 0
        Paper.apply(to: plate)
        plateMask.backgroundColor = .black
        plate.mask = plateMask
        rowsClip.addSubview(plate)

        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsClip.addSubview(rowsStack)

        // The stack hangs from the bottom; rows that do not fit leave at the top.
        let stackTop = rowsStack.topAnchor.constraint(greaterThanOrEqualTo: rowsClip.topAnchor)
        stackTop.priority = .defaultHigh
        rowsBottom = rowsStack.bottomAnchor.constraint(equalTo: rowsClip.bottomAnchor)
        // The content reaches as high as the owner lets it, so a row fading out at the top of a
        // shorter list is never cut by the clip.
        let fill = content.heightAnchor.constraint(equalToConstant: 10_000)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            rowsClip.topAnchor.constraint(equalTo: content.topAnchor),
            rowsClip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rowsClip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rowsClip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: rowsClip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsClip.trailingAnchor),
            rowsBottom,
            stackTop,
            fill,
            favoritesStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            favoritesStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            favoritesStrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            favoritesStrip.heightAnchor.constraint(equalToConstant: FavoritesStrip.height),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        addGestureRecognizer(tap)

        // A full list's rows are made now, not on the first keystroke's frame.
        spareRows = (0..<FixedChoices.maxAddressBarSuggestions).map { _ in makeRow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        rowsClip.layoutIfNeeded()
        // The plate covers the whole sheet, so its paper lines up with the sheet's.
        let plateFrame = rowsClip.convert(bounds, from: self)
        if plate.frame != plateFrame {
            UIView.performWithoutAnimation { plate.frame = plateFrame }
        }
        guard !isApplying else { return }
        // The space can change under the rows (keyboard, fold): only whole rows show.
        for row in shownRows {
            let fits = fits(row)
            if row.fits != fits { setFits(fits, row) }
        }
        UIView.performWithoutAnimation { plateMask.frame = rowsArea() }
    }

    /// Shows `suggestions`, best first, the first one nearest the field. Applied once per run
    /// loop turn, just before the frame is committed.
    func show(_ suggestions: [AddressBarSuggestion]) {
        pending = suggestions
        scheduleFlush()
    }

    /// Whether the favorites strip may show: only while the field is empty.
    func setFavoritesAllowed(_ allowed: Bool) {
        guard allowed != showsFavorites else { return }
        showsFavorites = allowed
        scheduleFlush()
    }

    func setFavorites(_ favorites: [FavoritePage]) {
        favoritesStrip.show(favorites)
        hasFavorites = !favorites.isEmpty
        scheduleFlush()
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

    // MARK: Applying a list

    /// Applies the newest list (and the favorites' visibility) at the end of this run loop turn,
    /// before Core Animation commits the frame: lists that land in the same turn make one change.
    private func scheduleFlush() {
        guard flushObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, false, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        flushObserver = observer
    }

    private func flush() {
        if let flushObserver {
            CFRunLoopObserverInvalidate(flushObserver)
            self.flushObserver = nil
        }
        let list = pending ?? current
        pending = nil
        apply(list)
    }

    private func apply(_ suggestions: [AddressBarSuggestion]) {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval(Signposts.suggestionsApply)
        defer { signposter.endInterval(Signposts.suggestionsApply, signpost) }
        let items = Array(suggestions.prefix(FixedChoices.maxAddressBarSuggestions))
        let showFavorites = showsFavorites && hasFavorites
        guard items != current || showFavorites != favoritesShown else { return }
        current = items

        if Motion.prefersCrossfade, window != nil {
            Motion.crossfade(content) {
                self.update(items, showFavorites: showFavorites, animated: false)
            }
        } else {
            update(items, showFavorites: showFavorites, animated: window != nil)
        }
        topUpSpareRows()
    }

    private func update(_ items: [AddressBarSuggestion], showFavorites: Bool, animated: Bool) {
        // The first rows after an empty list show at once, readable on the keystroke's frame:
        // there is no text there to crossfade from.
        let fillsEmpty = shownRows.isEmpty && leavingRows.isEmpty
        // Where every row is on screen now, mid-animation included, in the clip's space.
        var before: [ObjectIdentifier: (frame: CGRect, alpha: CGFloat)] = [:]
        for row in shownRows + leavingRows {
            before[ObjectIdentifier(row)] = presented(row)
        }

        // Match suggestions to rows by identity and place: a suggestion that stays in its place
        // keeps its row. One that changes place crossfades there: its row fades out where it was
        // (it leaves) while another row with the same suggestion fades in at the new place.
        // Nothing slides while typing, so every place on screen only ever crossfades from one
        // text to the next, and rows never drift past each other.
        var shownByID: [String: SuggestionRow] = [:]
        for row in shownRows { if let id = row.identity { shownByID[id] = row } }
        var next: [SuggestionRow] = []
        var entering: Set<ObjectIdentifier> = []
        for (index, item) in items.enumerated() {
            let id = SuggestionRow.identity(of: item)
            let row: SuggestionRow
            if let kept = shownByID[id], kept.place == index {
                shownByID[id] = nil
                row = kept
            } else if let back = leavingRows.firstIndex(where: { $0.identity == id && $0.place == index }) {
                // Still fading out at this place: it comes back from where it is.
                row = leavingRows.remove(at: back)
                row.leaveToken += 1
                row.removeFromSuperview()
                row.prepareForList()
            } else {
                row = spareRows.popLast() ?? makeRow()
                row.prepareForList()
                entering.insert(ObjectIdentifier(row))
            }
            row.configure(item, index: index)
            row.place = index
            next.append(row)
        }
        let leaving = shownRows.filter { row in row.identity.map { shownByID[$0] === row } ?? false }

        // The stack runs top to bottom, so the best row (first) goes last.
        for row in leaving { rowsStack.removeArrangedSubview(row); row.removeFromSuperview() }
        for (position, row) in next.reversed().enumerated() where
            position >= rowsStack.arrangedSubviews.count || rowsStack.arrangedSubviews[position] !== row {
            rowsStack.insertArrangedSubview(row, at: position)
        }
        shownRows = next
        rowsBottom.constant = showFavorites ? -FavoritesStrip.height : 0
        isApplying = true
        UIView.performWithoutAnimation { layoutIfNeeded() }
        isApplying = false

        // Leaving rows fade out where they stand, over the stack.
        for row in leaving {
            let seen = before[ObjectIdentifier(row)] ?? (row.frame, row.alpha)
            row.layer.removeAllAnimations()
            row.leaveToken += 1
            row.translatesAutoresizingMaskIntoConstraints = true
            row.transform = .identity
            row.frame = seen.frame
            row.alpha = seen.alpha
            row.isUserInteractionEnabled = false
            row.accessibilityElementsHidden = true
            row.accessibilityIdentifier = nil
            if animated {
                rowsClip.addSubview(row)
                leavingRows.append(row)
            } else {
                spareRows.append(row)
            }
        }

        // Each staying row starts from where it is on screen; a new one from nothing, in place.
        var moves: [(SuggestionRow, CGFloat)] = []
        for row in next {
            let target: CGFloat = fits(row) ? 1 : 0
            row.fits = target == 1
            row.isUserInteractionEnabled = row.fits
            row.accessibilityElementsHidden = !row.fits
            if entering.contains(ObjectIdentifier(row)) || !animated {
                let fades = animated && !fillsEmpty
                row.layer.removeAllAnimations()
                row.transform = .identity
                row.alpha = fades ? 0 : target
                if fades { moves.append((row, target)) }
                continue
            }
            guard let seen = before[ObjectIdentifier(row)] else {
                row.alpha = target
                continue
            }
            let now = clipFrame(of: row)
            let offset = seen.frame.midY - now.midY
            let moved = abs(offset) > 0.5
            if !moved, abs(seen.alpha - target) < 0.01, row.layer.animationKeys()?.isEmpty ?? true {
                continue
            }
            // Its place moved on screen though its index did not (the favorites came or went):
            // it fades in at the new place rather than sliding there.
            row.layer.removeAllAnimations()
            row.transform = .identity
            row.alpha = moved ? 0 : seen.alpha
            moves.append((row, target))
        }
        // VoiceOver reads best first.
        rowsStack.accessibilityElements = next.filter(\.fits)

        let plateAlpha: CGFloat = next.isEmpty ? 0 : 1
        if fillsEmpty, animated { plate.layer.removeAllAnimations(); plate.alpha = plateAlpha }
        let area = rowsArea()
        if !animated {
            plate.alpha = plateAlpha
            UIView.performWithoutAnimation { plateMask.frame = area }
            setFavoritesShown(showFavorites, animated: false)
            return
        }
        // The paper grows at once (rows fade in on it) and shrinks with the rows leaving.
        if area.height >= plateMask.frame.height || plate.alpha == 0 {
            plateMask.layer.removeAllAnimations()
            UIView.performWithoutAnimation { plateMask.frame = area }
        }
        let leavingNow = leaving.filter { leavingRows.contains($0) }.map { ($0, $0.leaveToken) }
        setFavoritesShown(showFavorites, animated: true)
        // Linear: where one text replaces another, their opacities add up to one throughout.
        let options: UIView.AnimationOptions = [.curveLinear, .allowUserInteraction, .beginFromCurrentState]
        UIView.animate(withDuration: Motion.suggestionFade, delay: 0, options: options) {
            for (row, alpha) in moves {
                row.transform = .identity
                row.alpha = alpha
            }
            for (row, _) in leavingNow { row.alpha = 0 }
            self.plate.alpha = plateAlpha
            if !area.isEmpty { self.plateMask.frame = area }
        } completion: { [weak self] _ in
            guard let self else { return }
            for (row, token) in leavingNow { self.finishLeaving(row, token: token) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !didWarmRows else { return }
        didWarmRows = true
        // Well after the frame that showed the sheet: never on the launch path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.warmRows() }
    }

    /// Lays the spare rows out once, out of sight, with a page and a search: the first keystroke
    /// then doesn't pay for their fonts, symbols and constraints in its frame.
    private func warmRows() {
        guard shownRows.isEmpty, leavingRows.isEmpty, pending == nil else { return }
        let samples: [AddressBarSuggestion] = [
            .page(url: URL(string: "https://example.com/a")!, title: "Example", isFavorite: false), .search("example"),
        ]
        let rows = spareRows
        UIView.performWithoutAnimation {
            for (index, row) in rows.enumerated() {
                row.prepareForList()
                row.alpha = 0
                row.configure(samples[index % samples.count], index: index)
                rowsStack.addArrangedSubview(row)
            }
            layoutIfNeeded()
            for row in rows {
                rowsStack.removeArrangedSubview(row)
                row.removeFromSuperview()
                row.alpha = 1
            }
            layoutIfNeeded()
        }
    }

    /// Keeps a full list's worth of rows ready, made after the frame that used them up rather
    /// than during the next keystroke's frame.
    private func topUpSpareRows() {
        guard spareRows.count < FixedChoices.maxAddressBarSuggestions, !isToppingUp else { return }
        isToppingUp = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isToppingUp = false
            let signposter = Signposts.signposter
            let signpost = signposter.beginInterval(Signposts.suggestionsApply, "spare rows")
            while self.spareRows.count < FixedChoices.maxAddressBarSuggestions {
                self.spareRows.append(self.makeRow())
            }
            signposter.endInterval(Signposts.suggestionsApply, signpost)
        }
    }

    private func finishLeaving(_ row: SuggestionRow, token: Int) {
        guard row.leaveToken == token, let index = leavingRows.firstIndex(of: row) else { return }
        leavingRows.remove(at: index)
        row.removeFromSuperview()
        spareRows.append(row)
    }

    private func makeRow() -> SuggestionRow {
        let row = SuggestionRow()
        row.addAction(UIAction { [weak self, weak row] _ in
            guard let self, let pick = row?.pick else { return }
            self.onPick(pick)
        }, for: .touchUpInside)
        return row
    }

    /// Fades the favorites in or out. They sit under the rows, so rows arriving cover them.
    private func setFavoritesShown(_ shown: Bool, animated: Bool) {
        guard shown != favoritesShown else { return }
        favoritesShown = shown
        favoritesToken += 1
        let token = favoritesToken
        favoritesStrip.isHidden = false
        favoritesStrip.accessibilityElementsHidden = !shown
        favoritesStrip.isUserInteractionEnabled = shown
        guard animated else {
            favoritesStrip.alpha = shown ? 1 : 0
            favoritesStrip.isHidden = !shown
            return
        }
        UIView.animate(
            withDuration: Motion.suggestionFade, delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
            self.favoritesStrip.alpha = shown ? 1 : 0
        } completion: { [weak self] _ in
            guard let self, self.favoritesToken == token else { return }
            self.favoritesStrip.isHidden = !shown
        }
    }

    // MARK: Geometry

    /// A row's frame and opacity as on screen now (mid-animation included), in the clip's space.
    private func presented(_ row: SuggestionRow) -> (frame: CGRect, alpha: CGFloat) {
        let layer = row.layer.presentation() ?? row.layer
        guard let superview = row.superview else { return (.zero, 0) }
        return (superview.convert(layer.frame, to: rowsClip), CGFloat(layer.opacity))
    }

    /// A row's resting frame (its transform left out), in the clip's space.
    private func clipFrame(of row: SuggestionRow) -> CGRect {
        let size = row.bounds.size
        let center = (row.superview ?? rowsStack).convert(row.center, to: rowsClip)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Only whole rows show: one that would be cut by the top edge stays out.
    private func fits(_ row: SuggestionRow) -> Bool {
        clipFrame(of: row).minY >= -0.5
    }

    private func setFits(_ fits: Bool, _ row: SuggestionRow) {
        row.fits = fits
        row.isUserInteractionEnabled = fits
        row.accessibilityElementsHidden = !fits
        row.alpha = fits ? 1 : 0
        rowsStack.accessibilityElements = shownRows.filter(\.fits)
    }

    /// The part of the plate behind the rows that show, in the plate's space.
    private func rowsArea() -> CGRect {
        let showing = shownRows.filter(\.fits)
        guard let top = showing.map({ clipFrame(of: $0).minY }).min(),
              let bottom = showing.map({ clipFrame(of: $0).maxY }).max()
        else { return .zero }
        let rect = CGRect(x: 0, y: top, width: rowsClip.bounds.width, height: bottom - top)
        return plate.convert(rect, from: rowsClip)
    }
}

/// A container that takes no touches itself, only through its subviews: the rows' clip covers the
/// whole sheet content, and taps on its empty space reach the favorites under it or the sheet.
final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// One suggestion: a page (from history or favorites) or a search from the engine.
final class SuggestionRow: UIControl {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    var pick: SearchPick?
    /// The suggestion this row shows, as `identity(of:)` names it.
    private(set) var identity: String?
    private var shown: AddressBarSuggestion?
    private var shownIndex = -1
    /// Whether the row fits in the space above the field (only whole rows show).
    var fits = true
    /// The row's index in the list (0 is the best, nearest the field); a leaving row keeps the
    /// one it had.
    var place = -1
    /// Bumped whenever the row starts or stops fading out, so a stale fade's end is ignored.
    var leaveToken = 0

    /// What makes two suggestions the same row across keystrokes: a page's address (as
    /// `AddressBarSuggestions` dedupes it) or a search's text, ignoring case.
    static func identity(of suggestion: AddressBarSuggestion) -> String {
        switch suggestion {
        case .page(let url, _, _, _): "page " + AddressBarSuggestions.addressKey(url)
        case .search(let query): "search " + query.lowercased()
        }
    }

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
            {
                // Rows keep their natural height (taller only for larger text).
                let natural = heightAnchor.constraint(equalToConstant: Metrics.rowHeight)
                natural.priority = .defaultLow + 1
                return natural
            }(),
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

    /// Resets a row taken from the spares or called back from fading out, before it joins the list.
    func prepareForList() {
        translatesAutoresizingMaskIntoConstraints = false
        transform = .identity
        alpha = 1
        isUserInteractionEnabled = true
        accessibilityElementsHidden = false
        isHighlighted = false
    }

    func configure(_ suggestion: AddressBarSuggestion, index: Int) {
        // A row that keeps its suggestion and place is left alone: nothing to redraw.
        guard suggestion != shown || index != shownIndex || accessibilityIdentifier == nil else { return }
        shown = suggestion
        shownIndex = index
        identity = Self.identity(of: suggestion)
        switch suggestion {
        case .page(let url, let pageTitle, let isFavorite, let isSaved):
            let address = Self.displayAddress(url)
            let name = pageTitle.flatMap { $0.isEmpty ? nil : $0 }
            setText(title, name ?? address)
            setText(detail, name == nil ? nil : address)
            if detail.isHidden != (name == nil) { detail.isHidden = name == nil }
            setSymbol(isFavorite ? "star" : isSaved ? "eyeglasses" : "clock")
            pick = .page(url)
            accessibilityIdentifier = "suggestion.page.\(index)"
            accessibilityLabel = title.text
            accessibilityValue = detail.text
        case .search(let query):
            setText(title, query)
            setText(detail, nil)
            if !detail.isHidden { detail.isHidden = true }
            setSymbol("magnifyingglass")
            pick = .search(query)
            accessibilityIdentifier = "suggestion.search.\(index)"
            accessibilityLabel = query
            accessibilityValue = nil
        }
    }

    private func setText(_ label: UILabel, _ text: String?) {
        if label.text != text { label.text = text }
    }

    private var symbol: String?
    private func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        icon.image = UIImage(systemName: name)
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

/// Favorites above the keyboard: a row of tiles that scrolls sideways when there are many. A long
/// press anywhere on it offers "Edit Favorites".
final class FavoritesStrip: UIView, UIContextMenuInteractionDelegate, UIScrollViewDelegate {
    static let height: CGFloat = 88
    var onPick: (URL) -> Void = { _ in }
    var onEdit: () -> Void = {}
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    /// Fades the edge where more favorites wait, so a cut tile reads as "scrolls".
    private let edgeFade = CAGradientLayer()
    private static let fadeWidth: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.delegate = self
        addSubview(scroll)
        edgeFade.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFade.endPoint = CGPoint(x: 1, y: 0.5)
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
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            Signposts.signposter.emitEvent(Signposts.favoritesMenu)
            let edit = UIAction(title: "Edit Favorites", image: UIImage(systemName: "pencil")) { _ in
                self?.onEdit()
            }
            edit.accessibilityIdentifier = "menu.editFavorites"
            return UIMenu(children: [edit])
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The content size comes from the stack's layout inside the scroll view.
        scroll.layoutIfNeeded()
        updateEdgeFade()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateEdgeFade()
    }

    /// Each edge fades only while there is more beyond it. Scrolling changes only the mask's
    /// colors; nothing lays out.
    private func updateEdgeFade() {
        let width = bounds.width
        let overflow = scroll.contentSize.width - width
        guard width > 0, overflow > 1 else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let offset = scroll.contentOffset.x
        let leading = min(1, max(0, offset / Self.fadeWidth))
        let trailing = min(1, max(0, (overflow - offset) / Self.fadeWidth))
        let fade = Double(Self.fadeWidth / width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if edgeFade.frame != bounds { edgeFade.frame = bounds }
        let opaque = UIColor.black.cgColor
        edgeFade.colors = [
            UIColor.black.withAlphaComponent(1 - leading).cgColor, opaque, opaque,
            UIColor.black.withAlphaComponent(1 - trailing).cgColor,
        ]
        edgeFade.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        if layer.mask !== edgeFade { layer.mask = edgeFade }
        CATransaction.commit()
    }

    func show(_ favorites: [FavoritePage]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, favorite) in favorites.enumerated() {
            let tile = FavoriteTile(favorite)
            tile.accessibilityIdentifier = "favorite.\(index)"
            tile.addAction(UIAction { [weak self] _ in self?.onPick(favorite.url) }, for: .touchUpInside)
            stack.addArrangedSubview(tile)
        }
        setNeedsLayout()
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
