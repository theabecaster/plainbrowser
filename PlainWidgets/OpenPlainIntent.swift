import AppIntents
import PlainShared

// Compiled into both the app and the widget extension (project.yml): a control's action opens
// the app only when its intent belongs to both targets (WidgetKit, "Open your app with a
// control"). It always runs in the app (`allowedExecutionTargets`).

/// Where a control takes Plain.
nonisolated enum PlainScreen: String, AppEnum {
    case search
    case privateTab

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [PlainScreen: DisplayRepresentation] = [
        .search: "Search",
        .privateTab: "New Private Tab",
    ]
}

/// The Control Center and Lock Screen controls' action: opens Plain on the search field, or on a
/// new private tab. Not offered in Shortcuts, which has Search in Plain and New Private Tab.
struct OpenPlainIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Plain"
    static let isDiscoverable = false
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "Screen")
    var target: PlainScreen

    init() {}

    init(target: PlainScreen) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        CommandInbox.shared.send(target == .search ? .focusSearch : .newPrivateTab)
        return .result()
    }
}
