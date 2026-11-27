#if canImport(UIKit)
import BrowserCore
import DesignSystem
import PerfSignposts
import UIKit
import WebEngine

/// Features the user, a parent or iOS has switched off for Plain (docs/ui-reference.md,
/// "Switched-off features"; docs/research/permissions-states.md). One quiet line at the moment of
/// need, once per site until the switch changes, with Settings where Plain's page there can turn
/// it back on. Never at launch, never an alert, never a dead button.
extension BrowserViewController {
    // MARK: SystemAccessPresenter (part of EngineHost)

    public func tab(_ tab: Tab, wasDenied features: [SystemFeature], forSite site: String) {
        guard tab === currentTab else { return }
        let monitor = session.pool.systemAccess
        if features == [.photos] {
            // Save Image is the user's own action: it is always answered, here with why.
            guard let notice = SystemAccessRules.photosNotice(monitor.access(.photos)) else { return }
            Haptic.nothingThere.play()
            showNotice(notice)
            return
        }
        let access = { monitor.access($0) }
        guard let notice = SystemAccessRules.notice(for: features, access: access),
              engineUI.accessNotices.shouldShow(features, site: site, access: access) else { return }
        showNotice(notice)
    }

    public func pool(_ pool: WebViewPool, systemAccessDidChange features: Set<SystemFeature>) {
        engineUI.accessNotices.forget(features)
        guard features.contains(.cellular), let tab = currentTab else { return }
        if engineUI.networkBlockedTab == tab.id, pool.systemAccess.networkBlock == nil {
            // Cellular data is back on for Plain: the page the user wanted loads by itself.
            engineUI.networkBlockedTab = nil
            if let url = tab.loadError?.url ?? tab.url { tab.load(url) } else { tab.reload() }
        } else {
            updatePageState()
        }
    }

    // MARK: Showing

    /// The line as a toast over the chrome, with Settings when Plain's page there can help.
    func showNotice(_ notice: SystemAccessNotice) {
        Signposts.signposter.emitEvent(Signposts.systemAccessNotice, "\(notice.message, privacy: .public)")
        showToastWhenFree { [weak self] in
            guard let self else { return }
            if notice.opensSettings {
                tabsUI.toast.show(notice.message, button: FixedChoices.switchedOffToastButton) { Self.openSettings() }
            } else {
                tabsUI.toast.show(notice.message)
            }
        }
    }

    /// Plain's page in the Settings app, where its camera, microphone, location, Photos and
    /// cellular data switches are.
    static func openSettings() {
        Signposts.signposter.emitEvent(Signposts.openSettings)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Site Settings

    /// The permissions the site on screen has asked for, each with its value: Allowed, Not
    /// Allowed, Off in Settings (a tap opens Settings) or Off on This iPhone (Screen Time, dimmed).
    /// A tap on Allowed or Not Allowed changes the site's answer. Nothing for a site that never
    /// asked.
    func sitePermissionMenuItems(for tab: Tab) -> [UIMenuElement] {
        let answers = session.pool.rememberedPermissions(for: tab)
        guard !answers.isEmpty else { return [] }
        let monitor = session.pool.systemAccess
        var items: [UIMenuElement] = []
        for permission in SitePermission.allCases {
            let system = permission.systemFeature.map { monitor.access($0) } ?? .allowed
            guard let value = SystemAccessRules.siteValue(remembered: answers[permission], system: system) else { continue }
            let action = UIAction(
                title: Self.permissionTitle(permission), subtitle: value.label,
                image: UIImage(systemName: Self.permissionSymbol(permission)), state: value == .allowed ? .on : .off
            ) { [weak self, weak tab] _ in
                guard let self, let tab else { return }
                switch value {
                case .offInSettings:
                    Self.openSettings()
                case .notAllowedOnPhone:
                    break
                case .allowed, .notAllowed:
                    let allow = value == .notAllowed
                    Signposts.signposter.emitEvent(
                        Signposts.sitePermissionChange, "\(permission.rawValue, privacy: .public) \(allow ? "allow" : "deny", privacy: .public)"
                    )
                    session.pool.setPermission(permission, allowed: allow, for: tab)
                    Haptic.selection.play()
                    // Taken back: the page loses it from its next load, as blocking applies.
                    if !allow { tab.reload() }
                }
            }
            if value == .notAllowedOnPhone { action.attributes = .disabled }
            action.accessibilityIdentifier = "menu.permission.\(permission.rawValue)"
            items.append(action)
        }
        return items.isEmpty ? [] : [UIMenu(options: .displayInline, children: items)]
    }

    static func permissionTitle(_ permission: SitePermission) -> String {
        switch permission {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .motion: "Motion"
        }
    }

    static func permissionSymbol(_ permission: SitePermission) -> String {
        switch permission {
        case .camera: "camera"
        case .microphone: "mic"
        case .location: "location"
        case .motion: "gyroscope"
        }
    }
}

extension SitePermission {
    /// The iOS switch a site's permission also needs; motion has none.
    var systemFeature: SystemFeature? {
        switch self {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        case .motion: nil
        }
    }
}
#endif
