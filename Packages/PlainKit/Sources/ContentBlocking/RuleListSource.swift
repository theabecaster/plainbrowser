import CryptoKit
import Foundation

/// One content-blocking rule list in WebKit's JSON format, before it is compiled.
///
/// Compiled lists are cached by `identifier`, which includes a hash of the JSON, so a changed list
/// compiles once and an unchanged one is looked up (`lookUpContentRuleList(forIdentifier:)`)
/// instead of compiled. Lists are never compiled at launch (docs/plan.md, section 4).
public struct RuleListSource: Sendable {
    public let name: String
    public let json: Data

    public init(name: String, json: Data) {
        self.name = name
        self.json = json
    }

    /// `name` plus the first 16 hex digits of the JSON's SHA-256.
    public var identifier: String {
        let digest = SHA256.hash(data: json).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(name)-\(digest)"
    }
}
