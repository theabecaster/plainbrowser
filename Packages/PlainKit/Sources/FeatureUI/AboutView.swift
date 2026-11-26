import Foundation
import SwiftUI

/// Settings > About. The first SwiftUI leaf screen; it shows the app's name and build.
public struct AboutView: View {
    private let info = Bundle.main.infoDictionary ?? [:]

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Text(info["CFBundleDisplayName"] as? String ?? "Plain").font(.largeTitle.bold())
            Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
                .foregroundStyle(.secondary)
        }
    }
}
