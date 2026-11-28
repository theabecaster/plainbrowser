#if canImport(UIKit)
import BrowserCore
import DesignSystem
import FeatureUI
import PerfSignposts
import Storage
import UIKit
import WebEngine

// MARK: - Tabs: the tabs button, its menu, bar swipe hand-offs, archive, link menu

extension BrowserViewController {
    /// The bar's gestures (swipe between tabs, swipe up to the gallery) apply: the bar is expanded
    /// and nothing covers it.
    var acceptsBarGestures: Bool {
        // Not while the search sheet still holds the pill (the last frames of its close).
        !isEditingAddress && !sheetUI.isLaidOutOpen && !isShowingGallery && presentedViewController == nil
            && !isChromeCollapsed && currentRules().acceptsBarGestures
    }

    /// The tabs slot (docs/state-rules.md §3): the gallery whenever it has a card, one page tab
    /// included, as the swipe up. Pressed while the gallery is up, it goes back to the page.
    func tabsButtonTapped() {
        // With side tabs, the button shows and hides the sidebar; the gallery stays in the menu.
        if !isShowingGallery, toggleSidebar() { return }
        if isShowingGallery {
            if let id = currentTab?.id, tabsUI.galleryTabs?.isShowingPrivateTabs == currentTab?.isPrivate {
                galleryOpenTab(id)
            } else {
                dismissGalleryFading()
            }
            return
        }
        switch currentRules().tabsSlot {
        case .tabs:
            if presentGallery(source: "button") != nil || isShowingGallery { tabsUI.tip.galleryOpenedByTap() }
        case .hidden: Haptic.nothingThere.play()
        }
    }

    /// The tabs button's menu (a long press), built when it opens. Every bar gesture has its item
    /// here, and the item names the gesture (docs/ui-reference.md).
    func tabsMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.tabsMenuElements() ?? [])
            },
        ])
    }

    /// The tabs menu, item by item from `ControlRules` (docs/state-rules.md §5).
    private func tabsMenuElements() -> [UIMenuElement] {
        TabsMenuTip.menuOpened()
        let rules = currentRules()
        var opening: [UIMenuElement] = []
        if rules.menuNewTab {
            let newTab = UIAction(title: "New Tab", image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.openNewTab(private: false)
            }
            newTab.accessibilityIdentifier = "menu.newTab"
            opening.append(newTab)
        }
        if rules.menuNewPrivateTab {
            let newPrivate = UIAction(title: "New Private Tab", image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                self?.openNewTab(private: true)
            }
            newPrivate.accessibilityIdentifier = "menu.newPrivateTab"
            opening.append(newPrivate)
        }
        var moves: [UIMenuElement] = []
        if rules.menuPreviousTab.isVisible {
            let previous = UIAction(
                title: "Previous Tab", subtitle: "Or swipe the address bar right", image: UIImage(systemName: "chevron.backward.square"),
                attributes: rules.menuPreviousTab.isEnabled ? [] : .disabled
            ) { [weak self] _ in self?.tabsUI.swipe.switchTab(side: -1) }
            previous.accessibilityIdentifier = "menu.previousTab"
            moves.append(previous)
        }
        if rules.menuNextTab.isVisible {
            let next = UIAction(
                title: "Next Tab", subtitle: "Or swipe the address bar left", image: UIImage(systemName: "chevron.forward.square"),
                attributes: rules.menuNextTab.isEnabled ? [] : .disabled
            ) { [weak self] _ in self?.tabsUI.swipe.switchTab(side: 1) }
            next.accessibilityIdentifier = "menu.nextTab"
            moves.append(next)
        }
        if rules.menuShowAllTabs {
            let all = UIAction(
                title: "Show All Tabs", subtitle: "Or swipe up from the address bar", image: UIImage(systemName: "square.grid.2x2")
            ) { [weak self] _ in self?.presentGallery(source: "menu") }
            all.accessibilityIdentifier = "menu.allTabs"
            moves.append(all)
        }
        var later: [UIMenuElement] = []
        if rules.menuReopenClosedTab { later.append(reopenClosedTabAction()) }
        if rules.menuArchivedTabs { later.append(archivedTabsAction()) }
        // New Window and the app's other windows, where windows exist (`+Windows`).
        let windows = windowMenuItems()
        var sections = [opening, moves, windows, later].filter { !$0.isEmpty }.map {
            UIMenu(options: .displayInline, children: $0) as UIMenuElement
        }
        if rules.menuCloseTab, let tab = currentTab {
            let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.closeTab(tab, offerReopen: true)
            }
            close.accessibilityIdentifier = "menu.closeTab"
            var closes: [UIMenuElement] = [close]
            if rules.menuCloseAllPrivateTabs {
                let all = UIAction(
                    title: "Close All Private Tabs", image: UIImage(systemName: "hand.raised.slash"), attributes: .destructive
                ) { [weak self] _ in self?.closeAllPrivateTabs() }
                all.accessibilityIdentifier = "menu.closeAllPrivateTabs"
                closes.append(all)
            }
            sections.append(UIMenu(options: .displayInline, children: closes))
        }
        return sections
    }

    /// Close All Private Tabs from the tabs menu: every private tab goes (none come back) and the
    /// screen returns to the regular tab seen last, else the search field, as after the last
    /// private tab's close.
    func closeAllPrivateTabs() {
        let wasShown = currentTab?.isPrivate == true
        if wasShown { clearPage() }
        session.tabs.closeAll(private: true)
        tabsUI.toast.hide(animated: true)
        guard wasShown else { return updateButtons() }
        if let regular = session.tabs.mostRecent(private: false) {
            show(session.tabs.tab(regular))
        } else if let next = session.tabs.selected, !next.isPrivate {
            show(next)
        } else {
            beginAddressEditing()
        }
    }

    /// The tabs menu's other items for More's top section, in every state where they apply
    /// (docs/state-rules.md §4): one visible tap away, not only behind the long press.
    func tabItemsForMore(_ rules: ControlRules) -> [UIMenuElement] {
        let opensPrivate = rules.moreNewTabOpensPrivate
        // On an empty private tab it turns this tab regular: "Leave Private", as the start screen.
        let newTab = UIAction(
            title: opensPrivate ? "New Private Tab" : "Leave Private",
            image: UIImage(systemName: opensPrivate ? "hand.raised" : "hand.raised.slash")
        ) { [weak self] _ in
            self?.openNewTab(private: opensPrivate)
        }
        newTab.accessibilityIdentifier = opensPrivate ? "more.newPrivateTab" : "more.leavePrivate"
        var items: [UIMenuElement] = [newTab]
        if rules.moreReopenClosedTab { items.append(reopenClosedTabAction(identifier: "more.reopenClosedTab")) }
        if rules.moreArchivedTabs { items.append(archivedTabsAction(identifier: "more.archivedTabs")) }
        return items
    }

    private func reopenClosedTabAction(identifier: String = "menu.reopenClosedTab") -> UIAction {
        let action = UIAction(title: "Reopen Closed Tab", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
            self?.reopenLastClosed(source: "menu")
        }
        action.accessibilityIdentifier = identifier
        return action
    }

    private func archivedTabsAction(identifier: String = "menu.archivedTabs") -> UIAction {
        let action = UIAction(title: "Archived Tabs", image: UIImage(systemName: "archivebox")) { [weak self] _ in
            self?.showArchive()
        }
        action.accessibilityIdentifier = identifier
        if !sheets.isReady { action.attributes = .disabled }
        return action
    }

    /// Reopen Closed Tab from a menu or the start screen: the last closed batch, on screen.
    func reopenLastClosed(source: StaticString) {
        let ids = session.tabs.reopenLastClosed()
        guard !ids.isEmpty, let tab = session.tabs.selected else { return Haptic.nothingThere.play() }
        endAddressEditing()
        show(tab)
    }

    /// New Tab and New Private Tab: an empty tab, straight to the search field. An empty tab of the
    /// same kind already on screen is reused, so empty tabs never pile up (state rules, principle 7).
    func openNewTab(private isPrivate: Bool) {
        OpenIntervals.begin(Signposts.newTabReady, until: UIResponder.keyboardDidShowNotification)
        OpenIntervals.begin(Signposts.newTabKeyboardStart, until: UIResponder.keyboardWillShowNotification)
        // From the gallery the page under it is not where the user was: no way back to it.
        let fromGallery = isShowingGallery
        if fromGallery { dismissGalleryFading() }
        if let current = currentTab, current.isPrivate == isPrivate, session.tabs.isEmpty(current.id) {
            beginAddressEditing()
            return
        }
        // From a page: closing the field untouched goes back to it (`returnFromUntouchedNewTab`).
        let back = fromGallery ? nil : currentTab.flatMap { session.tabs.isEmpty($0.id) ? nil : $0.id }
        let pane = session.tabs.focusedPane
        let tab = session.tabs.newTab(isPrivate: isPrivate)
        show(tab)
        tabsUI.newTabReturn = back.map { NewTabReturn(made: tab.id, back: $0, pane: pane) }
        beginAddressEditing()
    }

    /// The user closed the search sheet (`dismissSearchSheet`: a swipe down, a tap on the page,
    /// the grabber, Cancel, Escape). Over a New Tab opened from a page, with nothing typed and
    /// nothing opened, the page comes back and the empty tab, left, drops by itself (state rules,
    /// principle 7), so a stray "+" or swipe costs nothing. Arc's search over a page works the same
    /// way. Typed text keeps the new tab; so does the field closing for any other reason
    /// (backgrounding, a sheet, the gallery, a pane). Called before the field ends (which clears
    /// the way back), so the closing sheet lands on the page.
    func returnFromUntouchedNewTab(_ pending: NewTabReturn?, untouched: Bool) {
        guard untouched, let pending, currentTab?.id == pending.made, session.tabs.isEmpty(pending.made),
              session.tabs.focusedPane == pending.pane,
              let back = session.tabs.existingTab(pending.back), !isShownInOtherPane(back.id) else { return }
        Signposts.signposter.emitEvent(Signposts.barNewTab, "returned")
        show(back)
    }

    /// The bar's New Tab button: a tab of the kind on screen, like the swipe past the last tab, so
    /// a private page's "+" stays private. No haptic: the result is on screen (haptics plan, rule 1).
    func newTabButtonTapped() {
        Signposts.signposter.emitEvent(Signposts.barNewTab, "tap")
        openNewTab(private: currentTab?.isPrivate ?? false)
    }

    /// The New Tab button's long press: the other kind, the one a tap does not open.
    func newTabButtonMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                let isPrivate = self?.currentTab?.isPrivate ?? false
                let other = UIAction(
                    title: isPrivate ? "New Tab" : "New Private Tab", image: UIImage(systemName: isPrivate ? "plus" : "hand.raised")
                ) { [weak self] _ in
                    Signposts.signposter.emitEvent(Signposts.barNewTab, "menu")
                    self?.openNewTab(private: !isPrivate)
                }
                other.accessibilityIdentifier = isPrivate ? "newTabMenu.regular" : "newTabMenu.private"
                completion([other])
            },
        ])
    }

    /// A bar swipe past the last tab let go on the New Tab card.
    func openNewTabFromSwipe() {
        openNewTab(private: currentTab?.isPrivate ?? false)
    }

    /// A bar swipe landed on `tab`: it takes the page. `cover`, the picture that stood in for a tab
    /// without a web view, stays over the page until the restored page has loaded.
    func completeTabSwipe(to tab: Tab, cover: UIView?) {
        show(tab)
        guard let cover else { return }
        cover.frame = webContainer.bounds
        webContainer.addSubview(cover)
        Task { [weak self, weak tab, weak cover] in
            // Up to 1.5 s: long enough for most restores, short enough never to look stuck.
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let tab, self?.currentTab === tab else { break }
                if !tab.isLoading, tab.tier == .live, tab.url != nil { break }
            }
            guard let cover else { return }
            Motion.animate(Motion.quick, changes: { cover.alpha = 0 }) { cover.removeFromSuperview() }
        }
    }

    // MARK: Neighbour previews

    /// Before `incoming` replaces `outgoing` on screen: a neighbour of the new tab keeps a 2x
    /// full-screen picture of itself, taken now while its page is still in the window.
    func keepPreview(of outgoing: Tab, beside incoming: Tab) {
        let neighbours = session.tabs.neighbours(of: incoming.id)
        guard outgoing.id == neighbours.previous || outgoing.id == neighbours.next else { return }
        let id = outgoing.id
        session.pool.snapshot(of: outgoing, width: webContainer.bounds.width) { [weak self] image in
            guard let self, let image, let current = currentTab else { return }
            let now = session.tabs.neighbours(of: current.id)
            guard id == now.previous || id == now.next else { return }
            tabsUI.previews[id] = image
            tabsUI.fullPreviews.insert(id)
        }
    }

    /// Keeps pictures for the new tab's two neighbours only, and fetches a thumbnail for one
    /// without any (it has no web view and was not on screen this session).
    func refreshNeighbourPreviews() {
        guard let current = currentTab else {
            tabsUI.previews = [:]
            tabsUI.fullPreviews = []
            return
        }
        let neighbours = session.tabs.neighbours(of: current.id)
        let keep = Set([neighbours.previous, neighbours.next].compactMap { $0 })
        tabsUI.previews = tabsUI.previews.filter { keep.contains($0.key) }
        tabsUI.fullPreviews.formIntersection(keep)
        for id in keep where tabsUI.previews[id] == nil {
            Task { [weak self] in
                guard let image = await self?.session.pool.thumbnails.thumbnail(for: id), let self,
                      self.tabsUI.previews[id] == nil, let current = self.currentTab else { return }
                let now = self.session.tabs.neighbours(of: current.id)
                guard id == now.previous || id == now.next else { return }
                self.tabsUI.previews[id] = image
            }
        }
    }

    // MARK: Archive

    /// Moves idle tabs to the archive, at launch once the saved tabs and the settings are in, and
    /// on each return to the foreground (`settings.archiveAfter`, Settings > Archive Tabs).
    func archiveIdleTabs() {
        guard !tabsUI.isArchiving, session.tabs.isSessionLoaded, let setting = data.archiveAfter else { return }
        tabsUI.isArchiving = true
        Task { [weak self, session] in
            await session.tabs.archiveIdleTabs(after: setting)
            self?.tabsUI.isArchiving = false
        }
    }

    /// The Archive screen, from the gallery's menu, the tabs menu, More or the start screen.
    /// Restoring a tab closes it and opens the tab (from the gallery when it is up); a swipe
    /// deletes one for good.
    func showArchive() {
        if isEditingAddress { endAddressEditing() }
        let footer = (data.archiveAfter ?? FixedChoices.defaultArchiveAfter).archiveFooter
        let archive = sheets.archive(
            footer: footer,
            onRestore: { [weak self] archived in
                guard let self else { return }
                let tab = session.tabs.restoreArchived(archived)
                tabsUI.galleryTabs?.setShowingPrivateTabs(false)
                closeSheet { [weak self] in
                    guard let self else { return }
                    if isShowingGallery {
                        tabsUI.gallery?.reloadTabs(animated: false)
                        galleryOpenTab(tab.id)
                    } else {
                        show(tab)
                    }
                }
            },
            onDelete: { [weak self] ids in self?.session.tabs.deleteArchived(ids) },
            onDone: { [weak self] in self?.closeSheet() }
        )
        present(archive, signpost: Signposts.archiveShow)
    }

    // MARK: Toast

    /// Offers Reopen after a close outside the gallery, or one that left it (the gallery has its
    /// own toast). Reopen brings back exactly `batch`, the close it was made for, and follows the
    /// user: it shows over the page or the search field.
    func offerReopen(_ batch: UUID, message: String = String(localized: "Tab closed")) {
        tabsUI.toast.show(message, button: "Reopen") { [weak self] in
            guard let self else { return }
            Signposts.signposter.emitEvent(Signposts.tabReopen, "toast")
            guard !session.tabs.reopenClosed(batch).isEmpty, let tab = session.tabs.selected else {
                return Haptic.nothingThere.play()
            }
            endAddressEditing()
            show(tab)
        }
    }
}

// MARK: - Link menu

extension BrowserViewController {
    /// Where a split can show (the Duo's inner screen): it opens one, or uses the other pane.
    public func canOpenInOtherPane(from tab: Tab) -> Bool { canSplit }

    /// Open in New Tab shows the link at once; Open in Background loads it behind the page and
    /// says so with a toast that can show it.
    public func tab(_ tab: Tab, open url: URL, placement: LinkOpenPlacement) {
        switch placement {
        case .otherPane where canSplit:
            openInOtherPane(url, opener: tab)
        case .newWindow where canOpenNewWindow:
            openNewWindow(url, isPrivate: tab.isPrivate)
        case .newTab, .otherPane, .newWindow:
            let new = session.tabs.newTab(opener: tab)
            new.load(url)
            show(new)
        case .backgroundTab:
            let new = session.tabs.newTab(opener: tab, inBackground: true)
            new.load(url)
            Haptic.tap.play()
            tabsUI.toast.show("Opened in background", button: "Show") { [weak self, weak new] in
                guard let self, let new, session.tabs.entry(new.id) != nil else { return }
                show(new)
            }
        }
    }

    public func tab(_ tab: Tab, didComplete action: LinkMenuItem, succeeded: Bool) {
        guard succeeded else { return Haptic.nothingThere.play() }
        switch action {
        case .copyLink, .copyImage, .saveImage: Haptic.success.play()
        default: break
        }
    }
}
#endif
