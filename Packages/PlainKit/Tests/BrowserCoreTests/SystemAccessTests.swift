@testable import BrowserCore
import Foundation
import Testing

/// Switched-off features: which line shows for which state, once per site, and how Site Settings
/// reads a remembered answer under what iOS allows (docs/research/permissions-states.md).
@Suite struct SystemAccessTests {
    private func states(_ map: [SystemFeature: SystemAccess]) -> (SystemFeature) -> SystemAccess {
        { map[$0] ?? .allowed }
    }

    // MARK: A site's request

    @Test func nothingToSayWhileIOSAllowsOrWillAsk() {
        #expect(SystemAccessRules.notice(for: [.camera], access: states([.camera: .allowed])) == nil)
        // Not determined: the system's own prompt appears, never a line of Plain's before it.
        #expect(SystemAccessRules.notice(for: [.camera, .microphone], access: states([.camera: .notDetermined])) == nil)
        #expect(SystemAccessRules.notice(for: [], access: states([:])) == nil)
    }

    @Test func deniedNamesWhatIsOffAndOpensSettings() {
        let camera = SystemAccessRules.notice(for: [.camera], access: states([.camera: .denied]))
        #expect(camera == SystemAccessNotice(message: "Camera is off for Plain", opensSettings: true))
        let both = SystemAccessRules.notice(
            for: [.camera, .microphone], access: states([.camera: .denied, .microphone: .denied])
        )
        #expect(both?.message == "Camera and mic are off for Plain")
        // Only the blocked one is named.
        let mic = SystemAccessRules.notice(for: [.camera, .microphone], access: states([.microphone: .denied]))
        #expect(mic?.message == "Microphone is off for Plain")
        let location = SystemAccessRules.notice(for: [.location], access: states([.location: .denied]))
        #expect(location?.message == "Location is off for Plain")
    }

    @Test func locationServicesOffForThePhone() {
        let notice = SystemAccessRules.notice(for: [.location], access: states([.location: .servicesOff]))
        #expect(notice == SystemAccessNotice(message: "Location Services are off", opensSettings: true))
    }

    @Test func screenTimeExplainsWithoutAButton() {
        let notice = SystemAccessRules.notice(for: [.camera], access: states([.camera: .restricted]))
        #expect(notice == SystemAccessNotice(message: "Camera is restricted", opensSettings: false))
        let both = SystemAccessRules.notice(
            for: [.camera, .microphone], access: states([.camera: .restricted, .microphone: .restricted])
        )
        #expect(both?.message == "Camera and mic are restricted")
        // Restricted wins over denied: Settings could not fix the whole request.
        let mixed = SystemAccessRules.notice(
            for: [.camera, .microphone], access: states([.camera: .restricted, .microphone: .denied])
        )
        #expect(mixed?.opensSettings == false)
    }

    @Test func repeatedFeaturesAreNamedOnce() {
        let notice = SystemAccessRules.notice(for: [.camera, .camera], access: states([.camera: .denied]))
        #expect(notice?.message == "Camera is off for Plain")
    }

    // MARK: Save Image

    @Test func photos() {
        #expect(SystemAccessRules.photosNotice(.allowed) == nil)
        #expect(SystemAccessRules.photosNotice(.notDetermined) == nil)
        #expect(SystemAccessRules.photosNotice(.denied) == SystemAccessNotice(message: "Saving to Photos is off for Plain", opensSettings: true))
        #expect(SystemAccessRules.photosNotice(.restricted)?.opensSettings == false)
    }

    // MARK: Once per site

    @Test func oncePerSiteUntilTheStateChanges() {
        var memory = SystemAccessNoticeMemory()
        let denied = states([.location: .denied])
        do { let shown = memory.shouldShow([.location], site: "https://maps.example", access: denied); #expect(shown) }
        do { let shown = memory.shouldShow([.location], site: "https://maps.example", access: denied); #expect(!shown, "no nag on the next page") }
        do { let shown = memory.shouldShow([.location], site: "https://weather.example", access: denied); #expect(shown, "another site is told once too") }
        // Location Services turned off for the phone: a new state, told again.
        do { let shown = memory.shouldShow([.location], site: "https://maps.example", access: states([.location: .servicesOff])); #expect(shown) }
        // Allowed, then off again: forgotten on the change, so it shows once more.
        memory.forget([.location])
        do { let shown = memory.shouldShow([.location], site: "https://maps.example", access: denied); #expect(shown) }
    }

    @Test func memoryIgnoresWhatIsNotBlockedAndKeepsOtherFeatures() {
        var memory = SystemAccessNoticeMemory()
        do { let shown = memory.shouldShow([.camera], site: "https://a.example", access: states([:])); #expect(!shown) }
        let off = states([.camera: .denied, .location: .denied])
        do { let shown = memory.shouldShow([.camera], site: "https://a.example", access: off); #expect(shown) }
        do { let shown = memory.shouldShow([.location], site: "https://a.example", access: off); #expect(shown) }
        memory.forget([.camera])
        do { let shown = memory.shouldShow([.camera], site: "https://a.example", access: off); #expect(shown) }
        do { let shown = memory.shouldShow([.location], site: "https://a.example", access: off); #expect(!shown) }
        // A request for camera and microphone after the camera was told: the microphone is new.
        let both = states([.camera: .denied, .microphone: .denied, .location: .denied])
        do { let shown = memory.shouldShow([.camera, .microphone], site: "https://a.example", access: both); #expect(shown) }
        do { let shown = memory.shouldShow([.camera, .microphone], site: "https://a.example", access: both); #expect(!shown) }
    }

    // MARK: Site Settings

    @Test func siteSettingsValues() {
        #expect(SystemAccessRules.siteValue(remembered: nil, system: .denied) == nil, "a site that never asked has no row")
        #expect(SystemAccessRules.siteValue(remembered: true, system: .allowed) == .allowed)
        #expect(SystemAccessRules.siteValue(remembered: false, system: .allowed) == .notAllowed)
        #expect(SystemAccessRules.siteValue(remembered: true, system: .notDetermined) == .allowed)
        #expect(SystemAccessRules.siteValue(remembered: true, system: .denied) == .offInSettings)
        #expect(SystemAccessRules.siteValue(remembered: false, system: .servicesOff) == .offInSettings)
        #expect(SystemAccessRules.siteValue(remembered: true, system: .restricted) == .notAllowedOnPhone)
        // Asked while off for Plain: no answer, still a row with the way to change it.
        #expect(SystemAccessRules.siteValue(remembered: nil, askedWhileOff: true, system: .denied) == .offInSettings)
        #expect(SystemAccessRules.siteValue(remembered: nil, askedWhileOff: true, system: .servicesOff) == .offInSettings)
        #expect(SystemAccessRules.siteValue(remembered: nil, askedWhileOff: true, system: .restricted) == .notAllowedOnPhone)
        #expect(SystemAccessRules.siteValue(remembered: nil, askedWhileOff: true, system: .allowed) == nil, "on again: it asks again")
        #expect(SitePermissionValue.offInSettings.label == "Off in Settings")
        #expect(SitePermissionValue.notAllowedOnPhone.label == "Restricted")
    }

    // MARK: Network

    @Test func networkBlocks() {
        #expect(NetworkBlock.from(cellularDenied: false, wifiDenied: false, cellularRestricted: false, hasWiFi: false) == nil)
        #expect(NetworkBlock.from(cellularDenied: true, wifiDenied: false, cellularRestricted: false, hasWiFi: false) == .cellularOffForPlain)
        #expect(NetworkBlock.from(cellularDenied: false, wifiDenied: false, cellularRestricted: true, hasWiFi: false) == .cellularOffForPlain)
        // On Wi-Fi, cellular being off for Plain is not why a load failed.
        #expect(NetworkBlock.from(cellularDenied: false, wifiDenied: false, cellularRestricted: true, hasWiFi: true) == nil)
        #expect(NetworkBlock.from(cellularDenied: false, wifiDenied: true, cellularRestricted: false, hasWiFi: false) == .wifiOffForPlain)
        #expect(NetworkBlock.cellularOffForPlain.notice.message == "Cellular data is off for Plain.")
        #expect(NetworkBlock.cellularOffForPlain.notice.opensSettings)
    }
}
