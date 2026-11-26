// swift-tools-version: 6.2
import PackageDescription

// Build-time tool that turns the Adblock-syntax filter lists in `sources.json` into WebKit
// content-rule JSON for the ContentBlocking module. It runs on the Mac only and is never linked
// into the app: the app ships the generated JSON, not the converter.
//
// The converter is AdGuard's SafariConverterLib (GPL-3.0), which is compatible with Plain's
// AGPL-3.0-only license (GPLv3 section 13). See docs/decisions.md, "Content blocking lists".
//
// Run it with `tools/blocklists/generate.sh`.

let package = Package(
    name: "Blocklists",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned exactly: a converter change changes the generated rules, so it is a deliberate bump.
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "plain-blocklists",
            dependencies: [.product(name: "ContentBlockerConverter", package: "SafariConverterLib")]
        ),
    ]
)
