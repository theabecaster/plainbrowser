import CryptoKit
import Foundation

/// The bundled content-blocking lists, as described by `Resources/manifest.json`.
///
/// `tools/blocklists` generates the lists and this manifest at build time. The app never converts
/// filter lists itself; it only compiles the generated WebKit JSON, and only when a list's content
/// hash is not in the store yet.
public struct RuleListManifest: Codable, Sendable {
    public struct List: Codable, Sendable, Equatable {
        /// Stable name, for example `blocklist-01`. Every bundled list starts with `namePrefix`.
        public let name: String
        /// File name in the resource directory.
        public let file: String
        /// SHA-256 of the file, lowercase hex.
        public let sha256: String
        public let ruleCount: Int

        public init(name: String, file: String, sha256: String, ruleCount: Int) {
            self.name = name
            self.file = file
            self.sha256 = sha256
            self.ruleCount = ruleCount
        }

        /// `<name>-<hash>`: the name plus the first 16 hex digits of the file's SHA-256. A changed
        /// list gets a new identifier, so it compiles once; an unchanged one is looked up.
        public var identifier: String {
            "\(name)-\(sha256.prefix(16))"
        }
    }

    /// Every bundled list's name starts with this. Store entries with this prefix that the
    /// manifest does not name are old versions and get removed.
    public static let namePrefix = "blocklist-"

    public let lists: [List]

    public init(lists: [List]) {
        self.lists = lists
    }

    /// The directory that holds the bundled lists, the manifest and NOTICE.txt.
    public static var bundledDirectory: URL? {
        Bundle.module.url(forResource: "BlockLists", withExtension: nil)
    }

    /// Reads and decodes `manifest.json` from `directory`. Runs off the main thread.
    @concurrent
    public static func load(from directory: URL) async throws -> RuleListManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(RuleListManifest.self, from: data)
    }

    /// Reads one list's JSON for compiling and checks it against the manifest's hash, so a damaged
    /// file never compiles under the identifier of a good one. Runs off the main thread.
    ///
    /// Returns an `NSString` made off the main thread, so WebKit's compile call does not have to
    /// transcode a Swift string on the main thread.
    @concurrent
    static func readJSON(of list: List, in directory: URL) async throws -> SendableString {
        let data = try Data(contentsOf: directory.appendingPathComponent(list.file), options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == list.sha256 else { throw ContentBlockerError.hashMismatch(list.name) }
        guard let string = NSString(data: data, encoding: NSUTF8StringEncoding) else {
            throw ContentBlockerError.notUTF8(list.name)
        }
        return SendableString(value: string)
    }
}

/// An immutable `NSString` handed from a background read to the main actor.
struct SendableString: @unchecked Sendable {
    let value: NSString
}

public enum ContentBlockerError: Error, Equatable {
    case missingResources
    case hashMismatch(String)
    case notUTF8(String)
}
