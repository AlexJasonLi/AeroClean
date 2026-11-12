import Foundation
import Testing
@testable import MacCleanerCore

struct JunkRulesTests {
    let rules = JunkRules(
        home: "/Users/h",
        isInstalled: { $0 == "com.installed.app" },
        liveCursorExtensions: ["anthropic.claude-code-2.2.0-darwin-arm64"],
        obsoleteCursorExtensions: ["openai.chatgpt-26.1-darwin-arm64"]
    )

    func kind(_ relative: String) -> JunkKind? { rules.classify("/Users/h/" + relative).kind }

    @Test(arguments: [
        ("Library/Caches/com.example.app", JunkKind.cache),
        ("Library/Caches/GeoServices", .cache),
        ("Library/Caches/Homebrew", .downloadCache),
        ("Library/Caches/@granoladesktop-updater", .downloadCache),
        ("Library/Logs/JetBrains/IntelliJIdea2026.2", .logs),
        ("Library/Logs/Claude/main1.log", .logs),
        ("Library/Containers/com.apple.geod/Data/tmp/0011", .temporary),
        ("Library/Containers/us.zoom.xos/Data/Library/Caches/blob", .cache),
        ("Library/Saved Application State/com.gone.app.savedState", .leftover),
        ("Library/Developer/Xcode/DerivedData/Proj-abc", .buildCache),
        ("Library/Developer/Xcode/UserData/IB Support/Simulator Devices", .cache),
        ("Library/Developer/CoreSimulator/Devices/ABC/data/Library/Caches/com.x", .cache),
        ("Library/Developer/CoreSimulator/Devices/ABC/data/var/db/diagnostics", .logs),
        ("Library/Application Support/Adobe/Common/Media Cache Files/clip.ims", .cache),
        ("Library/Application Support/Granola/GPUCache", .cache),
        ("Library/Application Support/Steam/appcache/x", .cache),
        ("Library/Application Support/Steam/logs/cef_log.txt", .logs),
        ("Library/Application Support/Google/GoogleUpdater/crx_cache/abc", .downloadCache),
        ("Library/Application Support/Google/GoogleUpdater/updater.log.old", .logs),
        ("Library/Application Support/CrashReporter/Cursor_x.plist", .logs),
        ("project/server/app/__pycache__", .buildCache),
        ("Shop Site/.next/cache/webpack", .buildCache),
        (".npm/_cacache", .downloadCache),
        (".npm/_logs/2026.log", .logs),
        (".cargo/registry/cache/index.crates.io-1", .downloadCache),
        (".cache/uv", .downloadCache),
        (".expo/expo-go/abc-body.bin", .downloadCache),
        (".config/gcloud/logs/2026", .logs),
        (".cursor/extensions/anthropic.claude-code-2.1.318-darwin-arm64", .oldExtension),
        (".cursor/extensions/openai.chatgpt-26.1-darwin-arm64", .oldExtension),
        (".lunarclient/game-cache/x", .cache),
        (".zcompdump-host-5.9", .cache),
    ])
    func vouchesFor(_ relative: String, _ expected: JunkKind) {
        #expect(kind(relative) == expected, "\(relative)")
    }

    @Test(arguments: [
        "Library/Developer/CoreSimulator/Devices/ABC/data/private/var/MobileAsset/AssetsV2",
        "Library/Developer/CoreSimulator/Devices/ABC/data/Library/Application Support/PRBPosterExtensionDataStore",
        "Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage/abc",
        "Library/Application Support/Cursor/snapshots",
        "Library/Application Support/Claude/vm_bundles",
        "Library/Caches",
        "Library/Caches/com.apple.bird",
        "Library/Caches/CloudKit/x",
        "Library/Caches/com.apple.nsurlsessiond/Downloads",
        "Library/Logs",
        "Library/Saved Application State/com.installed.app.savedState",
        "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        "Library/Developer/Xcode/Archives/2026",
        ".cursor/extensions/anthropic.claude-code-2.2.0-darwin-arm64",
        ".cursor/extensions/extensions.json",
        ".cursor/extensions/someone.unknown-1.0.0-universal",
        ".cache/codex-runtimes",
        ".cache/puppeteer",
        ".npm/_npx",
        ".lesshst",
        ".wget-hsts",
        "Documents/report.pdf",
        "project/.git/objects",
    ])
    func doubts(_ relative: String) {
        #expect(kind(relative) == nil, "\(relative) should not count as junk")
    }

    @Test func doubtsAnythingOutsideHome() {
        #expect(rules.classify("/private/var/folders/zz/C/clang/ModuleCache").kind == nil)
    }

    @Test func namesTheAppsToQuit() {
        #expect(AppOwners.owners(of: "/Users/h/Library/Application Support/Adobe/Common/Media Cache Files/x").map(\.label) == ["Adobe apps"])
        #expect(AppOwners.owners(of: "/Users/h/Library/Developer/CoreSimulator/Devices/A/data").map(\.label) == ["Simulator"])
        #expect(AppOwners.owners(of: "/Users/h/.npm/_cacache").isEmpty)
    }
}
