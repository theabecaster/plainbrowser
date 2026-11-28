#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit
import UniformTypeIdentifiers

/// What a row or tile in the search sheet opens.
enum SearchPick: Equatable {
    case page(URL)
    case search(String)
    /// The page's own row: edit its address in the field.
    case editAddress
    /// The page's own row's Copy button.
    case copyAddress
    /// "Open Copied Link": the address, when Plain knows it without reading the pasteboard.
    case copiedLink(URL?)
    /// A recently closed batch, reopened where it was.
    case reopen(UUID)
}

/// One row of the search sheet: a suggestion while typing, or what the focused field offers
/// before typing (docs/decisions.md, "Address focus"). Rows are matched across updates by
/// `SuggestionRow.identity(of:)`, so a recent page that is also a suggestion keeps its row when
/// typing starts.
enum SheetItem: Hashable {
    case suggestion(AddressBarSuggestion)
    /// The page on screen (search over a page): its title and host, Copy, and a tap to edit.
    case currentPage(url: URL, title: String?)
    /// A web address on the pasteboard; the address itself only when Plain copied it.
    case copiedLink(URL?)
    /// A recently closed batch: its first tab's title and address, and how many tabs it holds.
    case closed(batch: UUID, url: URL?, title: String?, count: Int)
    /// One sentence when there is nothing else to show (first run).
    case hint(String)

    /// A visited page offered before typing: the same row a page suggestion uses.
    static func recent(url: URL, title: String?) -> SheetItem {
        .suggestion(.page(url: url, title: title, isFavorite: false))
    }
}

/// Where the open search sheet sits, in the sheet's own coordinates (the root view's). The shell
/// works it out from the bounds, the safe area and the pill's two frames before a layout pass;
/// the sheet only places what it is told (docs/research/arc-address-expand.md).
struct SheetPlacement: Equatable {
    enum Style: Equatable {
        /// The bottom bar grows up into a sheet: the card and the field ride up together, and
        /// the card runs to the bottom edge behind the keyboard (Arc Search).
        case sheet
        /// The top bar's field stays where it is and the card grows down from it (a wide
        /// screen's top bar).
        case dropdown
    }

    var style: Style
    /// The open card.
    var card: CGRect
    /// The open field (the pill), which the rows start under.
    var field: CGRect
    /// `.sheet`: how far below its open place the card rests while closed (the field's travel).
    var travel: CGFloat
    /// `.dropdown`: the card's height while closed (around the resting field).
    var closedHeight: CGFloat
    /// `.dropdown`: Cancel beside the field, inside the card.
    var showsCancel: Bool
}

/// The search sheet the URL pill grows into: a paper card over the dimmed page, the field at its
/// top (the pill itself, which the shell moves there) and the rows top-down right under it, best
/// first; favorites sit between the field and the rows while the field is empty.
///
/// Opening and closing are one progress value (0 closed, 1 open) the shell drives frame by frame
/// (`setProgress`): the card and everything on it are laid out once at their open place, and the
/// progress only translates, fades and (for a dropdown) resizes the card's clip, so no frame of
/// the motion lays anything out.
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
    /// How the sheet was asked to close, for the signpost.
    enum Dismissal: String { case outside, grabber, cancel, swipe, escape }

    /// The rows' container, under the field.
    let content = LayoutReportingView()
    var onPick: (SearchPick) -> Void = { _ in }
    /// A tap on the dimmed page outside the card, the grabber or Cancel: close the sheet.
    var onDismiss: (Dismissal) -> Void = { _ in }
    /// A drag on the card (`.sheet`): the shell moves the progress with the finger.
    var onPan: (UIPanGestureRecognizer) -> Void = { _ in }
    /// Browse for Me for what is typed (the row under the field).
    var onBrowse: (String) -> Void = { _ in }
    /// "Edit Favorites" from a long press on the favorites strip.
    var onEditFavorites: () -> Void = {} {
        didSet { favoritesStrip.onEdit = onEditFavorites }
    }

    /// Bumped each time the field opens or closes (the shell), so an answer that arrives late
    /// (the Paste button's) is only taken by the field it was for.
    var session = 0
    /// The card: the one surface the field and the rows sit on. It clips its content to its
    /// rounded top, and a dropdown's growth is its height.
    let card = UIView()
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let tint = UIView()
    /// The sheet's handle: it says "pull me down", and a tap on it closes too.
    private let grabber = UIButton(type: .custom)
    private let grabberBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let pan = UIPanGestureRecognizer()
    /// Follows the keyboard's top, so the sheet lays out again when the keyboard moves.
    private let keyboardProbe = UIView()
    private(set) var placement: SheetPlacement?
    private(set) var progress: CGFloat = 0
    private let rowsClip = PassThroughView()
    private let rowsStack = UIStackView()
    private var rowsTop: NSLayoutConstraint!
    /// The rows on screen, best first.
    private var shownRows: [SuggestionRow] = []
    /// Rows fading out where they stood, outside the stack.
    private var leavingRows: [SuggestionRow] = []
    /// Rows ready for reuse.
    private var spareRows: [SuggestionRow] = []
    /// The list waiting for the end of this run loop turn, and the observer that applies it.
    private var pending: [SheetItem]?
    private var flushObserver: CFRunLoopObserver?
    private var current: [SheetItem] = []
    private let favoritesStrip = FavoritesStrip()
    private let browseRow = BrowseForMeRow()
    /// The rows start at the content's top, or under Browse for Me's place.
    private var rowsOnContent: NSLayoutConstraint!
    private var rowsUnderBrowse: NSLayoutConstraint!
    private var showsFavorites = false
    private var hasFavorites = false
    private var favoritesShown = false
    private var favoritesToken = 0
    /// True while `update` lays out, so `layoutSubviews` leaves the rows to it.
    private var isApplying = false
    private var isToppingUp = false
    private var didWarmRows = false

    /// The card's corner radius as a sheet (Arc Search's, about 33 pt) and around a top bar's
    /// field (the field's capsule plus the card's margin, so the two curves are concentric).
    static let sheetRadius: CGFloat = 32
    /// The card's margin around a top bar's field.
    static let dropdownMargin: CGFloat = Spacing.s
    /// The field's distance under the sheet's top edge (Arc Search: 16 pt); the grabber sits in it.
    static let fieldInset: CGFloat = Spacing.l
    /// Between the field and the first row.
    private static let fieldGap: CGFloat = Spacing.s
    /// The rows' inset from the card's sides.
    private static let rowsInset: CGFloat = Spacing.s
    private static let grabberSize = CGSize(width: 36, height: 5)
    /// Over and under a row's text.
    static let rowTextInset: CGFloat = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "searchSheet"

        card.clipsToBounds = true
        card.layer.cornerCurve = .continuous
        card.accessibilityIdentifier = "searchCard"
        addSubview(card)
        material.isUserInteractionEnabled = false
        card.addSubview(material)
        // Paper over the blur: the card reads as Plain's paper with the page's colors faintly
        // through it, by day and by night.
        tint.isUserInteractionEnabled = false
        tint.backgroundColor = Palette.sheetTint
        card.addSubview(tint)

        grabberBar.backgroundColor = Palette.sheetGrabber
        grabberBar.layer.cornerRadius = Self.grabberSize.height / 2
        grabberBar.isUserInteractionEnabled = false
        grabber.addSubview(grabberBar)
        grabber.accessibilityIdentifier = "search.close"
        grabber.accessibilityLabel = String(localized: "Close Search")
        grabber.accessibilityHint = String(localized: "Swipe down on the sheet, or tap the page above it")
        grabber.addAction(UIAction { [weak self] _ in self?.onDismiss(.grabber) }, for: .touchUpInside)
        card.addSubview(grabber)

        var cancel = UIButton.Configuration.plain()
        cancel.title = String(localized: "Cancel")
        cancel.baseForegroundColor = Palette.accentOnPaper
        cancel.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Spacing.s, bottom: 0, trailing: Spacing.s)
        cancelButton.configuration = cancel
        cancelButton.maximumContentSizeCategory = .extraExtraExtraLarge
        cancelButton.accessibilityIdentifier = "search.cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.onDismiss(.cancel) }, for: .touchUpInside)
        cancelButton.isHidden = true
        card.addSubview(cancelButton)

        content.onLayout = { [weak self] in self?.layOutRows() }
        card.addSubview(content)

        // Under the rows: the favorites sit where the first rows would while the field is empty.
        favoritesStrip.onPick = { [weak self] url in self?.onPick(.page(url)) }
        favoritesStrip.translatesAutoresizingMaskIntoConstraints = false
        favoritesStrip.isHidden = true
        favoritesStrip.alpha = 0
        content.addSubview(favoritesStrip)

        rowsClip.clipsToBounds = true
        rowsClip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rowsClip)

        browseRow.translatesAutoresizingMaskIntoConstraints = false
        browseRow.addAction(UIAction { [weak self] _ in
            guard let self, let query = browseRow.query else { return }
            onBrowse(query)
        }, for: .touchUpInside)
        content.addSubview(browseRow)

        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsClip.addSubview(rowsStack)

        keyboardProbe.isHidden = true
        keyboardProbe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardProbe)

        // The stack hangs from the top; rows that do not fit above the keyboard stay out.
        rowsTop = rowsStack.topAnchor.constraint(equalTo: rowsClip.topAnchor)
        rowsOnContent = rowsClip.topAnchor.constraint(equalTo: content.topAnchor)
        rowsUnderBrowse = rowsClip.topAnchor.constraint(equalTo: browseRow.bottomAnchor)
        NSLayoutConstraint.activate([
            rowsClip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            rowsClip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rowsClip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rowsOnContent,
            browseRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            browseRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            browseRow.topAnchor.constraint(equalTo: content.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: rowsClip.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: rowsClip.trailingAnchor),
            rowsTop,
            favoritesStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            favoritesStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            favoritesStrip.topAnchor.constraint(equalTo: content.topAnchor),
            favoritesStrip.heightAnchor.constraint(equalToConstant: FavoritesStrip.height),
            keyboardProbe.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            keyboardProbe.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardProbe.widthAnchor.constraint(equalToConstant: 1),
            keyboardProbe.heightAnchor.constraint(equalToConstant: 1),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        addGestureRecognizer(tap)
        pan.addTarget(self, action: #selector(panned))
        pan.delegate = self
        card.addGestureRecognizer(pan)

        // A full list's rows are made now, not on the first keystroke's frame.
        spareRows = (0..<FixedChoices.maxAddressBarSuggestions).map { _ in makeRow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Placement and progress

    /// Where the open sheet sits. The card and its content take their open frames in the next
    /// layout pass (the caller's, before the frame that shows them).
    func place(_ placement: SheetPlacement) {
        guard placement != self.placement else { return }
        self.placement = placement
        setNeedsLayout()
    }

    /// How open the sheet is: 0 closed (nothing of it shows), 1 open. Transform and alpha only,
    /// plus the card's own height for a dropdown, whose content is pinned to its top and does not
    /// lay out with it.
    func setProgress(_ progress: CGFloat) {
        self.progress = progress
        guard let placement else { return }
        let p = min(max(progress, 0), 1)
        // The surface is there almost at once (Arc: the bar turns to material in ~4 frames).
        card.alpha = min(1, p / 0.15)
        let inner = min(1, max(0, (p - 0.05) / 0.3))
        content.alpha = inner
        grabber.alpha = inner
        cancelButton.alpha = inner
        switch placement.style {
        case .sheet:
            card.transform = CGAffineTransform(translationX: 0, y: placement.travel * (1 - p))
        case .dropdown:
            card.transform = .identity
            let frame = cardFrame(placement, progress: p)
            guard card.bounds.height != frame.height else { return }
            card.bounds.size.height = frame.height
            card.center.y = frame.midY
        }
    }

    /// The card's frame at `progress`, its transform aside: the open frame for a sheet (which
    /// only translates), the grown part of it for a dropdown.
    private func cardFrame(_ placement: SheetPlacement, progress: CGFloat) -> CGRect {
        guard placement.style == .dropdown else { return placement.card }
        var frame = placement.card
        frame.size.height = placement.closedHeight + (frame.height - placement.closedHeight) * progress
        return frame
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let placement else { return }
        let frame = placement.card
        // The card as it stands at this progress, so a layout pass mid-motion changes nothing.
        let shown = cardFrame(placement, progress: min(max(progress, 0), 1))
        let transform = card.transform
        card.transform = .identity
        if card.frame != shown { card.frame = shown }
        card.transform = transform
        let isSheet = placement.style == .sheet
        card.layer.cornerRadius = isSheet ? Self.sheetRadius : placement.field.height / 2 + Self.dropdownMargin
        card.layer.maskedCorners = isSheet
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        pan.isEnabled = isSheet
        let surface = CGRect(origin: .zero, size: frame.size)
        if material.frame != surface {
            material.frame = surface
            tint.frame = surface
        }
        // The handle, centered in the band over the field; its tap target is the whole band.
        grabber.isHidden = !isSheet
        grabber.frame = CGRect(x: frame.width / 2 - 44, y: 0, width: 88, height: Self.fieldInset)
        grabberBar.frame = CGRect(
            x: (grabber.bounds.width - Self.grabberSize.width) / 2, y: 6,
            width: Self.grabberSize.width, height: Self.grabberSize.height
        )
        let field = placement.field.offsetBy(dx: -frame.minX, dy: -frame.minY)
        cancelButton.isHidden = !placement.showsCancel
        if placement.showsCancel {
            cancelButton.frame = CGRect(
                x: field.maxX, y: field.minY, width: frame.width - field.maxX, height: field.height
            )
        }
        // The rows: under the field, down to the keyboard (or the bottom edge without one).
        let top = field.maxY + Self.fieldGap
        let keyboardTop = keyboardProbe.frame.minY - frame.minY
        let bottom = min(frame.height, keyboardTop) - Spacing.xxs
        let area = CGRect(
            x: Self.rowsInset, y: top, width: frame.width - 2 * Self.rowsInset, height: max(0, bottom - top)
        )
        if content.frame != area { content.frame = area }
        setProgress(progress)
        layOutRows()
    }

    /// Only whole rows show: the space can change under them (keyboard, fold).
    private func layOutRows() {
        rowsClip.layoutIfNeeded()
        guard !isApplying else { return }
        for row in shownRows {
            let fits = fits(row)
            if row.fits != fits { setFits(fits, row) }
        }
    }

    /// The width Cancel needs beside a top bar's field.
    var cancelWidth: CGFloat {
        ceil(cancelButton.sizeThatFits(CGSize(width: 400, height: Metrics.tapTarget)).width)
    }

    @objc private func panned() {
        onPan(pan)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        // A drag down, more down than sideways (the favorites scroll sideways).
        let velocity = pan.velocity(in: self)
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }

    /// Shows `suggestions`, best first, the first one nearest the field. Applied once per run
    /// loop turn, just before the frame is committed.
    func show(_ suggestions: [AddressBarSuggestion]) {
        show(items: suggestions.map(SheetItem.suggestion))
    }

    /// Shows `items` (suggestions, or the focused field's content before typing), best first,
    /// the first one nearest the field. Applied once per run loop turn, like `show(_:)`.
    func show(items: [SheetItem]) {
        pending = items
        scheduleFlush()
    }

    /// Applies a waiting list now rather than at the end of the run loop turn: the sheet is
    /// opening, and its rows belong on the motion's first frame (the run loop may not come to
    /// rest for several frames while the keyboard starts).
    func applyPendingNow() {
        guard pending != nil || flushObserver != nil else { return }
        flush()
    }

    /// Empties the list at once (the sheet has closed and is out of sight).
    func clear() {
        pending = nil
        guard !current.isEmpty || favoritesShown else { return }
        current = []
        UIView.performWithoutAnimation { update([], showFavorites: false, animated: false) }
    }

    /// The most rows the sheet keeps: a full suggestion list, or the focused field's content
    /// (copied link, the page, recent pages, closed tabs). Rows that don't fit above the field
    /// stay out, so this only bounds the work.
    static let maxRows = max(
        FixedChoices.maxAddressBarSuggestions,
        2 + FixedChoices.focusReadingList + FixedChoices.focusRecentPages + FixedChoices.focusClosedTabs
    )

    /// Browse for Me's place under the field (`reserved`: something is typed and the on-device
    /// model can run) and the query it would browse for, or nil while the text is an address (the
    /// row fades out in place). The place opens with the first keystroke, when the focused rows
    /// give way to suggestions anyway, and stays while typing, so the suggestions never move
    /// (docs/state-rules.md §1, principle 5).
    func setBrowseForMe(reserved: Bool, query: String?) {
        if rowsUnderBrowse.isActive != reserved {
            rowsOnContent.isActive = !reserved
            rowsUnderBrowse.isActive = reserved
            browseRow.isHidden = !reserved
            setNeedsLayout()
        }
        // Over the favorites strip (an empty field) the row is never shown.
        browseRow.show(reserved ? query : nil, animated: !isApplying)
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
        onDismiss(.outside)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer !== pan else { return true }
        // Only taps on the dimmed page around the card, never on the card.
        return touch.view === self
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

    private func apply(_ suggestions: [SheetItem]) {
        let signposter = Signposts.signposter
        let signpost = signposter.beginInterval(Signposts.suggestionsApply)
        defer { signposter.endInterval(Signposts.suggestionsApply, signpost) }
        let items = Array(suggestions.prefix(Self.maxRows))
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

    private func update(_ items: [SheetItem], showFavorites: Bool, animated: Bool) {
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

        // The stack runs top to bottom, best first.
        for row in leaving { rowsStack.removeArrangedSubview(row); row.removeFromSuperview() }
        for (position, row) in next.enumerated() where
            position >= rowsStack.arrangedSubviews.count || rowsStack.arrangedSubviews[position] !== row {
            rowsStack.insertArrangedSubview(row, at: position)
        }
        shownRows = next
        rowsTop.constant = showFavorites ? FavoritesStrip.height : 0
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

        if !animated {
            setFavoritesShown(showFavorites, animated: false)
            return
        }
        let leavingNow = leaving.filter { leavingRows.contains($0) }.map { ($0, $0.leaveToken) }
        // Into an empty sheet (it just opened) the favorites show at once, like the rows.
        setFavoritesShown(showFavorites, animated: !fillsEmpty)
        // Linear: where one text replaces another, their opacities add up to one throughout.
        let options: UIView.AnimationOptions = [.curveLinear, .allowUserInteraction, .beginFromCurrentState]
        UIView.animate(withDuration: Motion.suggestionFade, delay: 0, options: options) {
            for (row, alpha) in moves {
                row.transform = .identity
                row.alpha = alpha
            }
            for (row, _) in leavingNow { row.alpha = 0 }
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
        let samples: [SheetItem] = [
            .recent(url: URL(string: "https://example.com/a")!, title: "Example"), .suggestion(.search("example")),
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
        row.onAccessory = { [weak self] in self?.onPick(.copyAddress) }
        row.onPaste = { [weak self] url, session in
            guard let self, session == self.session else { return }
            self.onPick(.copiedLink(url))
        }
        row.sessionProvider = { [weak self] in self?.session ?? 0 }
        return row
    }

    /// The page's row answers a copy with its check mark.
    func confirmCopied() {
        shownRows.first { $0.identity?.hasPrefix("current ") == true }?.showCopied()
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

    /// Only whole rows show: one that would be cut by the keyboard (the clip's bottom) stays out.
    private func fits(_ row: SuggestionRow) -> Bool {
        clipFrame(of: row).maxY <= rowsClip.bounds.height + 0.5
    }

    private func setFits(_ fits: Bool, _ row: SuggestionRow) {
        row.fits = fits
        row.isUserInteractionEnabled = fits
        row.accessibilityElementsHidden = !fits
        row.alpha = fits ? 1 : 0
        rowsStack.accessibilityElements = shownRows.filter(\.fits)
    }
}

/// A view that says when it has laid out its subviews.
final class LayoutReportingView: UIView {
    var onLayout: () -> Void = {}

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
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

/// One row: a page (from history or favorites) or a search from the engine while typing, or
/// before typing the page on screen, a copied link, a closed tab or the first-run sentence.
final class SuggestionRow: UIControl {
    private let icon = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    /// The trailing slot: Copy on the page's own row, the system Paste button on the copied
    /// link's row (it hands Plain the link with no paste alert), empty elsewhere.
    private let slot = UIView()
    private let accessory = UIButton(type: .system)
    private var pasteControl: UIPasteControl?
    private var slotWidth: NSLayoutConstraint!
    private var textTrailing: NSLayoutConstraint!
    private enum Accessory { case none, copy, paste }
    private var accessoryKind = Accessory.copy
    /// The row's identifier while a button sits beside it (the row itself then is a container).
    private(set) var mainIdentifier: String?
    /// A link the Paste button handed over.
    var onPaste: (URL, Int) -> Void = { _, _ in }
    /// The open field's session (`SearchSheet.session`), read when Paste begins.
    var sessionProvider: () -> Int = { 0 }
    /// The row's main part for VoiceOver and UI tests while the accessory shows: the row itself
    /// then can't be one element, or Copy would be out of reach.
    private lazy var mainElement = RowElement(row: self)
    var pick: SearchPick?
    /// The accessory's action (Copy on the page's row).
    var onAccessory: () -> Void = {}
    /// The suggestion this row shows, as `identity(of:)` names it.
    private(set) var identity: String?
    private var shown: SheetItem?
    private var shownIndex = -1
    /// Whether the row fits in the space above the field (only whole rows show).
    var fits = true
    /// The row's index in the list (0 is the best, nearest the field); a leaving row keeps the
    /// one it had.
    var place = -1
    /// Bumped whenever the row starts or stops fading out, so a stale fade's end is ignored.
    var leaveToken = 0
    /// Bumped by each copy, so only the newest one's check mark turns back.
    private var copyToken = 0

    /// What makes two rows the same across updates: a page's address (as `AddressBarSuggestions`
    /// dedupes it) or a search's text, ignoring case; the focused field's own rows by kind.
    static func identity(of item: SheetItem) -> String {
        switch item {
        case .suggestion(.page(let url, _, _, _)): "page " + AddressBarSuggestions.addressKey(url)
        case .suggestion(.search(let query)): "search " + query.lowercased()
        case .currentPage(let url, _): "current " + AddressBarSuggestions.addressKey(url)
        case .copiedLink: "copied"
        case .closed(let batch, _, _, _): "closed " + batch.uuidString
        case .hint: "hint"
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

        var copy = UIButton.Configuration.plain()
        copy.image = UIImage(systemName: "link")
        copy.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        copy.baseForegroundColor = Palette.accentOnPaper
        accessory.configuration = copy
        accessory.accessibilityLabel = String(localized: "Copy Link")
        accessory.accessibilityIdentifier = "focus.copyAddress"
        // The glyph stays inside its 44 pt slot at the accessibility sizes (it ran off the edge).
        accessory.maximumContentSizeCategory = .extraExtraExtraLarge
        accessory.isHidden = true
        accessory.addAction(UIAction { [weak self] _ in self?.onAccessory() }, for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = Spacing.xxs
        text.isUserInteractionEnabled = false
        for view in [icon, text] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.clipsToBounds = true
        addSubview(slot)
        accessory.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(accessory)
        slotWidth = slot.widthAnchor.constraint(equalToConstant: 0)
        textTrailing = text.trailingAnchor.constraint(equalTo: slot.leadingAnchor)
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
            textTrailing,
            // Two lines at the default text size fit the 52 pt row (Arc Search's pitch), so four
            // rows show over the keyboard on the Duo's outer screen; larger text grows the row.
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: SearchSheet.rowTextInset),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -SearchSheet.rowTextInset),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.xs),
            slot.topAnchor.constraint(equalTo: topAnchor),
            slot.bottomAnchor.constraint(equalTo: bottomAnchor),
            slotWidth,
            accessory.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            accessory.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            accessory.widthAnchor.constraint(equalToConstant: Metrics.tapTarget),
            accessory.heightAnchor.constraint(equalToConstant: Metrics.tapTarget),
        ])
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])
        setAccessory(.none)
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

    func configure(_ item: SheetItem, index: Int) {
        // A row that keeps its item and place is left alone: nothing to redraw.
        guard item != shown || index != shownIndex || accessibilityIdentifier == nil else { return }
        shown = item
        shownIndex = index
        identity = Self.identity(of: item)
        var kind = Accessory.none
        var tint = Palette.textSecondary
        isEnabled = true
        switch item {
        case .suggestion(.page(let url, let pageTitle, let isFavorite, let isSaved)):
            setPage(url: url, title: pageTitle)
            setSymbol(isFavorite ? "star" : isSaved ? "eyeglasses" : "clock")
            pick = .page(url)
            accessibilityIdentifier = "suggestion.page.\(index)"
        case .suggestion(.search(let query)):
            setLines(query, nil)
            setSymbol("magnifyingglass")
            pick = .search(query)
            accessibilityIdentifier = "suggestion.search.\(index)"
        case .currentPage(let url, let pageTitle):
            setPage(url: url, title: pageTitle)
            setSymbol("pencil")
            tint = Palette.accentOnPaper
            pick = .editAddress
            kind = .copy
            accessibilityIdentifier = "focus.currentPage"
            accessibilityHint = String(localized: "Edits the address")
        case .copiedLink(let url):
            setLines(String(localized: "Open Copied Link"), url.map(Self.displayAddress))
            setSymbol("doc.on.clipboard")
            tint = Palette.accentOnPaper
            pick = .copiedLink(url)
            accessibilityIdentifier = "focus.copiedLink"
            // Another app's link: the system Paste button opens it with no alert. A tap on the
            // row reads it too, after the system asks. Isolated runs copy to a private
            // pasteboard, which the Paste button can't read.
            if url == nil, !TestIsolation.isActive { kind = .paste }
        case .closed(let batch, let url, let closedTitle, let count):
            let name = closedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? url.map(Self.displayAddress) ?? String(localized: "Closed Tab")
            var secondLine = url.map(Self.displayAddress)
            if count > 1 { secondLine = String(localized: "and \(count - 1) more tabs") }
            setLines(name, secondLine)
            setSymbol("arrow.uturn.backward")
            pick = .reopen(batch)
            accessibilityIdentifier = "focus.closed.\(index)"
            accessibilityHint = String(localized: "Reopens the closed tab")
        case .hint(let sentence):
            setLines(sentence, nil)
            setSymbol("binoculars")
            pick = nil
            isEnabled = false
            accessibilityIdentifier = "focus.hint"
        }
        if case .hint = item {
            title.numberOfLines = 0
            title.textColor = Palette.textSecondary
            title.font = .preferredFont(forTextStyle: .subheadline)
        } else {
            title.numberOfLines = 1
            title.textColor = Palette.textPrimary
            title.font = .preferredFont(forTextStyle: .body)
        }
        switch item {
        case .currentPage, .closed: break
        default: accessibilityHint = nil
        }
        icon.tintColor = tint
        accessibilityLabel = title.text
        accessibilityValue = detail.text
        accessibilityTraits = item.isHint ? .staticText : .button
        setAccessory(kind)
        // With a button beside it, the row's main part carries its identifier (UI tests, VoiceOver).
        mainIdentifier = accessibilityIdentifier
        if kind != .none { accessibilityIdentifier = (mainIdentifier ?? "") + ".row" }
    }

    /// A page: its title over its address, or the address alone.
    private func setPage(url: URL, title pageTitle: String?) {
        let address = Self.displayAddress(url)
        let name = pageTitle.flatMap { $0.isEmpty ? nil : $0 }
        setLines(name ?? address, name == nil ? nil : address)
    }

    private func setLines(_ text: String, _ second: String?) {
        setText(title, text)
        setText(detail, second)
        if detail.isHidden != (second == nil) { detail.isHidden = second == nil }
    }

    private func setAccessory(_ kind: Accessory) {
        guard kind != accessoryKind else { return }
        accessoryKind = kind
        accessory.isHidden = kind != .copy
        if kind == .paste, pasteControl == nil {
            let configuration = UIPasteControl.Configuration()
            configuration.displayMode = .labelOnly
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .white
            configuration.baseBackgroundColor = Palette.accent
            let control = UIPasteControl(configuration: configuration)
            control.target = self
            control.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(control)
            NSLayoutConstraint.activate([
                control.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: -Spacing.xs),
                control.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
            pasteControl = control
        }
        pasteControl?.isHidden = kind != .paste
        let width: CGFloat = switch kind {
        case .none: 0
        case .copy: Metrics.tapTarget
        case .paste: (pasteControl?.intrinsicContentSize.width ?? 64) + Spacing.s
        }
        slotWidth.constant = width
        textTrailing.constant = kind == .none ? -Spacing.m + Spacing.xs : -Spacing.xs
        // With a button beside it, the row's main part and the button are two elements.
        let button: UIView? = switch kind {
        case .none: nil
        case .copy: accessory
        case .paste: pasteControl
        }
        isAccessibilityElement = button == nil
        accessibilityElements = button.map { [mainElement, $0] }
    }

    /// The Paste button's link: a URL, or text that is one web address.
    override func paste(itemProviders: [NSItemProvider]) {
        // The field this Paste was for: a result that comes back after it closed is dropped.
        let session = sessionProvider()
        let deliver: @Sendable (URL?) -> Void = { [weak self] url in
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            Task { @MainActor in self?.onPaste(url, session) }
        }
        if let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in deliver(url) }
        } else if let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                // Text that is one web address ("www.example.com"), as the address bar reads it.
                guard let text, case .url(let url)? = AddressBarInput(text) else { return deliver(nil) }
                deliver(url)
            }
        }
    }

    /// Copy's answer: a check mark for a moment, said aloud for VoiceOver.
    func showCopied() {
        copyToken += 1
        let token = copyToken
        accessory.configuration?.image = UIImage(systemName: "checkmark")
        accessory.accessibilityLabel = String(localized: "Copied")
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
        DispatchQueue.main.asyncAfter(deadline: .now() + FixedChoices.copiedConfirmation) { [weak self] in
            guard let self, self.copyToken == token else { return }
            self.accessory.configuration?.image = UIImage(systemName: "link")
            self.accessory.accessibilityLabel = String(localized: "Copy Link")
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

    /// The row's main part as one VoiceOver element while Copy sits beside it.
    private final class RowElement: UIAccessibilityElement {
        weak var row: SuggestionRow?

        init(row: SuggestionRow) {
            self.row = row
            super.init(accessibilityContainer: row)
            accessibilityTraits = .button
        }

        override var accessibilityLabel: String? {
            get { row?.title.text }
            set {}
        }

        override var accessibilityValue: String? {
            get { row?.detail.text }
            set {}
        }

        override var accessibilityHint: String? {
            get { row?.accessibilityHint }
            set {}
        }

        override var accessibilityIdentifier: String? {
            get { row?.mainIdentifier }
            set {}
        }

        override var accessibilityFrameInContainerSpace: CGRect {
            get {
                guard let row else { return .zero }
                return CGRect(x: 0, y: 0, width: row.slot.frame.minX, height: row.bounds.height)
            }
            set {}
        }

        override func accessibilityActivate() -> Bool {
            row?.sendActions(for: .touchUpInside)
            return true
        }
    }
}

private extension SheetItem {
    var isHint: Bool { if case .hint = self { true } else { false } }
}


/// Favorites under the field: a row of tiles that scrolls sideways when there are many. A long
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
        caption.adjustsFontForContentSizeCategory = true
        // The strip keeps its height: at accessibility sizes the caption stops growing where it
        // still fits under the disc (it was cut in half there).
        caption.maximumContentSizeCategory = .extraExtraExtraLarge
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
