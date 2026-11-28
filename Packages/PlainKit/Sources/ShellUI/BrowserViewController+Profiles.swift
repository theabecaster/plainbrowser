#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import TabGalleryUI
import UIKit
import WebEngine

// MARK: - Profiles (docs/decisions.md, "Profiles, no tab groups")
//
// A profile is its own tabs, archive, history, favorites, and cookies and website data. The
// window's profile is the profile of the tab on screen; the gallery's switcher lists another
// profile's tabs, and opening one of them (or a new tab there) moves the window to it. Making,
// renaming and deleting profiles live in the switcher's menu (New Profile in More while there
// is only Personal).

extension BrowserViewController {
    func wireProfiles() {
        session.tabs.onProfileChange = { [weak self] profile in self?.profileDidChange(profile) }
        sheets.attachProfiles(session.profileData) { [weak session] in session?.tabs.profiles.map(\.id) ?? [] }
    }

    /// The window moved to another profile: history, favorites, typed-input learning and the
    /// archive follow it. Its history database opens off the main thread the first time.
    private func profileDidChange(_ profile: ProfileID) {
        data.profile = profile
        // The field never shows another profile's pages, not even for a moment.
        focusUI.content = .empty
        sheet.setFavorites([])
        sheets.useProfile(profile, database: nil)
        updateStartScreenMessage()
        Task { [weak self, session] in
            let database = await session.profileData.database(for: profile)
            guard let self, session.tabs.activeProfile == profile else { return }
            sheets.useProfile(profile, database: database)
            if let database { onProfileDatabaseChange?(database) }
            updateButtons()
            refreshFocusContent()
        }
    }

    /// The start screen names the profile once there is more than one, so a new search never
    /// starts in the wrong one unnoticed.
    func updateStartScreenMessage() {
        let message = startScreenMessage
        if tabsUI.start.message != message { tabsUI.start.message = message }
    }

    /// The window's profile's name while there are two or more profiles; nil with Personal alone,
    /// where naming it would say nothing, and in a private tab, which keeps nothing in any profile.
    var shownProfileName: String? {
        let tabs = session.tabs
        guard tabs.profiles.count > 1, currentTab?.isPrivate != true else { return nil }
        return tabs.store.profile(tabs.activeProfile)?.name
    }

    /// The start screen's sentence: an empty private tab says what it keeps (the screen is dark
    /// and titled "Private"); with two or more profiles a regular one names the window's profile.
    var startScreenMessage: String {
        // Under the "Private" title (EmptyTabView.setPrivate), so it needn't say private twice.
        if currentTab?.isPrivate == true { return String(localized: "Plain keeps no history of private tabs.") }
        let tabs = session.tabs
        guard tabs.profiles.count > 1, let name = tabs.store.profile(tabs.activeProfile)?.name else {
            return String(localized: "Start with a search or an address.")
        }
        return String(localized: "Start with a search or an address in \(name).")
    }

    // MARK: The switcher's menu

    /// Each profile (the shown one checked), New Profile, and Rename and Delete for the shown
    /// profile (never Delete for Personal).
    func galleryProfileMenu() -> [UIMenuElement] {
        guard let galleryTabs = tabsUI.galleryTabs else { return [] }
        let tabs = session.tabs
        let shown = galleryTabs.shownProfile
        let switches = tabs.profiles.map { profile in
            let action = UIAction(title: profile.name, state: profile.id == shown ? .on : .off) { [weak self] _ in
                self?.showProfile(profile.id)
            }
            action.accessibilityIdentifier = "profile.\(profile.name)"
            return action
        }
        var elements: [UIMenuElement] = [UIMenu(options: .displayInline, children: switches)]
        if tabs.store.canAddProfile {
            let add = UIAction(title: String(localized: "New Profile…"), image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.galleryNewProfile()
            }
            add.accessibilityIdentifier = "profile.new"
            elements.append(UIMenu(options: .displayInline, children: [add]))
        }
        guard let profile = tabs.store.profile(shown) else { return elements }
        let rename = UIAction(title: String(localized: "Rename Profile…"), image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.renameProfile(profile)
        }
        rename.accessibilityIdentifier = "profile.rename"
        elements.append(UIMenu(options: .displayInline, children: [rename]))
        if !profile.isDefault {
            let delete = UIAction(
                title: String(localized: "Delete Profile…"), image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in
                self?.confirmDeleteProfile(profile)
            }
            delete.accessibilityIdentifier = "profile.delete"
            // Destructive, so in its own last section.
            elements.append(UIMenu(options: .displayInline, children: [delete]))
        }
        return elements
    }

    /// The switcher lists `profile`'s tabs; the window keeps its profile until one is opened.
    private func showProfile(_ profile: ProfileID, tick: Bool = true) {
        guard let galleryTabs = tabsUI.galleryTabs, galleryTabs.shownProfile != profile || galleryTabs.isShowingPrivateTabs
        else { return }
        Signposts.signposter.emitEvent(Signposts.profileShow)
        galleryTabs.setShowingProfile(profile)
        tabsUI.gallery?.showList(tick: tick)
    }

    // MARK: New, rename, delete

    func galleryNewProfile() {
        let tabs = session.tabs
        // The first new profile is most often work, so the field suggests it.
        let suggestion = tabs.profiles.count == 1 ? String(localized: "Work") : nil
        askForProfileName(
            title: String(localized: "New Profile"),
            message: String(localized: "A profile has its own tabs, history, favorites and website logins."),
            action: String(localized: "Create"), placeholder: suggestion ?? String(localized: "Name"),
            isTaken: { tabs.store.isProfileNameTaken($0) }
        ) { [weak self] name in
            guard let self, let id = tabs.addProfile(named: name) else { return }
            Signposts.signposter.emitEvent(Signposts.profileCreate)
            Haptic.success.play()
            // Its empty list, with the switcher: the next tab opened there is the new profile's.
            showProfile(id, tick: false)
            tabsUI.gallery?.reloadTabs(animated: false)
        }
    }

    private func renameProfile(_ profile: Profile) {
        let tabs = session.tabs
        askForProfileName(
            title: String(localized: "Rename Profile"), message: nil, action: String(localized: "Rename"),
            placeholder: String(localized: "Name"), text: profile.name,
            isTaken: { tabs.store.isProfileNameTaken($0, besides: profile.id) }
        ) { [weak self] name in
            guard tabs.renameProfile(profile.id, to: name) else { return }
            Signposts.signposter.emitEvent(Signposts.profileRename)
            self?.tabsUI.gallery?.reloadTabs(animated: false)
            self?.updateStartScreenMessage()
        }
    }

    /// Asks once, saying what goes (docs/state-rules.md §6: no surprises), then deletes.
    private func confirmDeleteProfile(_ profile: Profile) {
        let count = session.tabs.entries(private: false, profile: profile.id).count
        let tabs = count == 0 ? "" : count == 1 ? String(localized: "1 open tab, ") : String(localized: "\(count) open tabs, ")
        let alert = UIAlertController(
            title: String(localized: "Delete “\(profile.name)”?"),
            message: String(localized: "This deletes \(tabs)archived tabs, history, favorites, website logins and site data in \(profile.name). This can't be undone."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Delete Profile"), style: .destructive) { [weak self] _ in
            self?.deleteProfile(profile.id)
        })
        alert.view.accessibilityIdentifier = "profile.deleteAlert"
        present(alert, animated: true)
    }

    private func deleteProfile(_ id: ProfileID) {
        Haptic.close.play()
        // The page goes first when it is the profile's: its web view is about to be released.
        let wasShown = currentTab.map { !$0.isPrivate && $0.profileID == id } ?? false
        if wasShown { clearPage() }
        session.tabs.deleteProfile(id)
        if wasShown, let next = session.tabs.selected { show(next) }
        tabsUI.galleryTabs?.setShowingProfile(session.tabs.activeProfile)
        tabsUI.gallery?.showList(tick: false)
        updateStartScreen()
        updateStartScreenMessage()
        // The tab list without the profile is written first, so a crash from here on never brings
        // the profile back without its data. Then the history waiting to be written, its
        // database and its website data store, off the main thread. The store is removed only
        // after its web views are gone (just closed).
        Task { [data, session] in
            // Not written (the disk refused): the data stays, and the profile comes back with it
            // at the next launch rather than coming back empty.
            guard await session.tabs.isProfileDeletionSaved(id) else { return }
            await data.forgetProfile(id)
            await session.profileData.remove(id)
            await AppWebsiteData.removeProfileData(id)
        }
    }

    /// A name sheet for New and Rename: the main button stays off while the name is empty or
    /// another profile's.
    private func askForProfileName(
        title: String, message: String?, action: String, placeholder: String, text: String? = nil,
        isTaken: @escaping (String) -> Bool, done: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let confirm = UIAlertAction(title: action, style: .default) { [weak alert] _ in
            guard let name = alert?.textFields?.first?.text else { return }
            done(name)
        }
        alert.addTextField { field in
            field.placeholder = placeholder
            field.text = text
            field.autocapitalizationType = .words
            field.returnKeyType = .done
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "profile.name"
            let check = { [weak field] in
                let name = field?.text ?? ""
                confirm.isEnabled = Profile.cleanName(name) != nil && !isTaken(name)
            }
            field.addAction(UIAction { _ in check() }, for: .editingChanged)
            check()
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(confirm)
        alert.preferredAction = confirm
        present(alert, animated: true)
    }
}
#endif
