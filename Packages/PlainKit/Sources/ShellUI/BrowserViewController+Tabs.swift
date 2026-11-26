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
        !isEditingAddress && !isShowingGallery && presentedViewController == nil && !isChromeCollapsed
    }

    /// The tabs button: the gallery. Pressed while the gallery is up, it goes back to the page.
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
        presentGallery(source: "button")
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

    private func tabsMenuElements() -> [UIMenuElement] {
        let newTab = UIAction(title: "New Tab", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.openNewTab(private: false)
        }
        newTab.accessibilityIdentifier = "menu.newTab"
        let newPrivate = UIAction(title: "New Private Tab", image: UIImage(systemName: "hand.raised")) { [weak self] _ in
            self?.openNewTab(private: true)
        }
        newPrivate.accessibilityIdentifier = "menu.newPrivateTab"
        var moves: [UIMenuElement] = []
        if let tab = currentTab {
            let neighbours = session.tabs.neighbours(of: tab.id)
            let next = UIAction(
                title: "Next Tab", subtitle: "Or swipe the address bar left", image: UIImage(systemName: "chevron.forward.square"),
                attributes: neighbours.next == nil ? .disabled : []
            ) { [weak self] _ in self?.tabsUI.swipe.switchTab(side: 1) }
            next.accessibilityIdentifier = "menu.nextTab"
            let previous = UIAction(
                title: "Previous Tab", subtitle: "Or swipe the address bar right", image: UIImage(systemName: "chevron.backward.square"),
                attributes: neighbours.previous == nil ? .disabled : []
            ) { [weak self] _ in self?.tabsUI.swipe.switchTab(side: -1) }
            previous.accessibilityIdentifier = "menu.previousTab"
            moves = [previous, next]
        }
        let all = UIAction(
            title: "Show All Tabs", subtitle: "Or swipe up from the address bar", image: UIImage(systemName: "square.grid.2x2")
        ) { [weak self] _ in self?.presentGallery(source: "menu") }
        all.accessibilityIdentifier = "menu.allTabs"
        var sections: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [newTab, newPrivate]),
            UIMenu(options: .displayInline, children: moves + [all]),
        ]
        if let tab = currentTab {
            let close = UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.closeTab(tab, offerReopen: true)
            }
            close.accessibilityIdentifier = "menu.closeTab"
            sections.append(UIMenu(options: .displayInline, children: [close]))
        }
        return sections
    }

    /// New Tab and New Private Tab: an empty tab, straight to the search field.
    func openNewTab(private isPrivate: Bool) {
        if isShowingGallery { dismissGalleryFading() }
        let tab = session.tabs.newTab(isPrivate: isPrivate)
        show(tab)
        beginAddressEditing()
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

    /// The Archive screen, from the gallery's menu. Restoring a tab closes it and opens the tab
    /// from the gallery; a swipe deletes one for good.
    func showArchive() {
        let footer = (data.archiveAfter ?? FixedChoices.defaultArchiveAfter).footer
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

    /// Offers Reopen Tab after a tab closes outside the gallery (the gallery has its own toast).
    func offerReopen() {
        tabsUI.toast.show("Tab closed", button: "Reopen") { [weak self] in
            guard let self else { return }
            Signposts.signposter.emitEvent(Signposts.tabReopen, "toast")
            session.tabs.reopenLastClosed()
            if let tab = session.tabs.selected { show(tab) }
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
        case .newTab, .otherPane:
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
