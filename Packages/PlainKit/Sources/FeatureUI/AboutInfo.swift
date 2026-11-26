import Foundation

/// What Settings > About shows: the version, where the source lives, and the license texts.
public nonisolated struct AboutInfo: Sendable {
    /// A license or notice text shipped with the app, read from disk only when opened.
    public struct Document: Sendable, Hashable, Identifiable {
        public var title: String
        public var fileURL: URL
        public var id: String { title }

        public init(title: String, fileURL: URL) {
            self.title = title
            self.fileURL = fileURL
        }
    }

    public var name: String
    public var version: String
    public var build: String
    public var sourceURL: URL
    public var documents: [Document]

    public init(name: String, version: String, build: String, sourceURL: URL = AboutInfo.sourceURL, documents: [Document]) {
        self.name = name
        self.version = version
        self.build = build
        self.sourceURL = sourceURL
        self.documents = documents
    }

    /// Plain is AGPL-3.0, so its source is always one tap away.
    public static let sourceURL = URL(string: "https://github.com/theabecaster/plainbrowser")!

    /// The main bundle's name and version. The app adds its license documents with `documents`.
    public static var current: AboutInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AboutInfo(
            name: info["CFBundleDisplayName"] as? String ?? "Plain",
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            documents: []
        )
    }

    /// "Version 0.1.0 (1)".
    public var versionLine: String { "Version \(version) (\(build))" }

    /// Reads a document's text off the main thread. Nil when it can't be read.
    @concurrent
    public static func text(of document: Document) async -> String? {
        try? String(contentsOf: document.fileURL, encoding: .utf8)
    }
}
