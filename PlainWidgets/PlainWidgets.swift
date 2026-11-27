import AppIntents
import SwiftUI
import WidgetKit
import WidgetUI

// The widget extension: a thin wrapper, like the app. The search widget's views and timeline live
// in Packages/PlainKit (WidgetUI); the controls are here because their intent must be compiled
// into this target too.

@main
struct PlainWidgets: WidgetBundle {
    var body: some Widget {
        SearchWidget()
        SearchControl()
        PrivateTabControl()
    }
}

/// Control Center, the Lock Screen and the Action button: Plain's search field in one press.
struct SearchControl: ControlWidget {
    static let kind = "dev.abrahamgonzalez.plainbrowser.control.search"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenPlainIntent(target: .search)) {
                Label("Search in Plain", systemImage: "magnifyingglass")
            }
        }
        .displayName("Search in Plain")
        .description("Opens Plain with the search field ready.")
    }
}

/// A new private tab in one press.
struct PrivateTabControl: ControlWidget {
    static let kind = "dev.abrahamgonzalez.plainbrowser.control.privateTab"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenPlainIntent(target: .privateTab)) {
                Label("New Private Tab", systemImage: "hand.raised")
            }
        }
        .displayName("New Private Tab")
        .description("Opens a private tab in Plain.")
    }
}
