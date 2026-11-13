import CoreServices
import Foundation

/// the kinds of junk AeroClean vouches for. each one is safe to remove because nothing
/// is lost: the item is rebuilt, fetched again, or never read.
public enum JunkKind: String, CaseIterable, Sendable, Codable {
    case cache, buildCache, downloadCache, logs, temporary, leftover, oldExtension

    public var title: String {
        switch self {
        case .cache: "App caches"
        case .buildCache: "Build caches"
        case .downloadCache: "Download caches"
        case .logs: "Logs and crash reports"
        case .temporary: "Temporary files"
        case .leftover: "Leftovers"
        case .oldExtension: "Old extensions"
        }
    }

    /// why removing it changes nothing.
    public var reason: String {
        switch self {
        case .cache: "Apps rebuild these on their own"
        case .buildCache: "Rebuilt on your next build"
        case .downloadCache: "Downloaded again only if needed"
        case .logs: "Records nothing needs to run"
        case .temporary: "Scratch files apps left behind"
        case .leftover: "From apps no longer on this Mac"
        case .oldExtension: "Replaced by newer versions"
        }
    }
}

public enum JunkVerdict: Equatable, Sendable {
    case junk(JunkKind)
    /// not something AeroClean can promise is safe; kept out of the junk list.
    case doubt(String)

    public var kind: JunkKind? { if case .junk(let kind) = self { kind } else { nil } }
}

/// decides, path by path, whether an item Mole lists is junk beyond doubt. anything that
/// matches no rule is a doubt. rules only ever say "safe" for places whose contents are
/// rebuilt, downloaded again or never read.
public struct JunkRules: Sendable {
    public let home: String
    /// bundle ids of installed apps, so leftovers of removed apps can be told apart.
    let isInstalled: @Sendable (String) -> Bool
    /// cursor extension folders cursor still loads, from its extensions.json.
    let liveCursorExtensions: Set<String>
    /// folders cursor itself marked obsolete in extensions/.obsolete.
    let obsoleteCursorExtensions: Set<String>

    public init(
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isInstalled: (@Sendable (String) -> Bool)? = nil,
        liveCursorExtensions: Set<String>? = nil,
        obsoleteCursorExtensions: Set<String>? = nil
    ) {
        self.home = home
        self.isInstalled = isInstalled ?? JunkRules.launchServicesKnows
        self.liveCursorExtensions = liveCursorExtensions ?? JunkRules.cursorExtensions(home: home)
        self.obsoleteCursorExtensions = obsoleteCursorExtensions ?? JunkRules.cursorObsolete(home: home)
    }

    // caches some apple services keep state in: removing them makes the service resync or misbehave.
    static let systemStateCaches: Set<String> = [
        "com.apple.bird", "com.apple.cloudd", "CloudKit", "com.apple.nsurlsessiond", "com.apple.akd",
        "com.apple.iCloudHelper", "com.apple.ap.adprivacyd", "FamilyCircle", "com.apple.containermanagerd",
        "com.apple.amsengagementd", "com.apple.appstoreagent", "com.apple.commerce", "com.apple.storeassetd",
    ]

    // download caches by folder name: package managers and updaters fetch these again on demand.
    static let downloadCaches: Set<String> = [
        "Homebrew", "pip", "pnpm", "Yarn", "yarn", "bun", "node-gyp", "typescript", "electron", "electron-builder",
        "org.swift.swiftpm", "CocoaPods", "go-build", "ffmpeg-static-nodejs", "claude-cli-nodejs", "uv",
        "pypoetry", "pre-commit", "deno",
    ]

    // folder names chromium and electron apps rebuild on every launch.
    static let rebuiltOnLaunch: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
        "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "appcache",
    ]

    public func classify(_ path: String) -> JunkVerdict {
        guard path.hasPrefix(home + "/") else { return .doubt("Outside your home folder") }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first else { return .doubt("Your home folder") }
        func part(_ index: Int) -> String? { index < parts.count ? parts[index] : nil }
        let name = parts.last!

        // never junk, wherever it sits.
        if parts.contains("Service Worker") { return .doubt("Website data, not only cache") }
        if parts.contains(".git") { return .doubt("Git history") }
        if [".lesshst", ".wget-hsts", ".python_history", ".node_repl_history", ".zsh_history", ".bash_history"].contains(name) {
            return .doubt("Your own history")
        }

        // anywhere: python bytecode and next.js build caches are rebuilt on the next run.
        if parts.contains("__pycache__") { return .junk(.buildCache) }
        if let next = parts.firstIndex(of: ".next"), part(next + 1) == "cache" { return .junk(.buildCache) }

        if first == "Library" {
            switch part(1) {
            case "Caches":
                guard let owner = part(2) else { return .doubt("The caches folder itself") }
                if Self.systemStateCaches.contains(owner) { return .doubt("A system service keeps state here") }
                if Self.downloadCaches.contains(owner) || owner.hasPrefix("@") && owner.hasSuffix("-updater") {
                    return .junk(.downloadCache)
                }
                return .junk(.cache)
            case "Logs":
                return parts.count > 2 ? .junk(.logs) : .doubt("The logs folder itself")
            case "Saved Application State":
                guard let state = part(2), state.hasSuffix(".savedState") else { return .doubt("Window state") }
                let bundle = String(state.dropLast(".savedState".count))
                return isInstalled(bundle) ? .doubt("Window positions of an app you have") : .junk(.leftover)
            case "Containers":
                // only a container's tmp and cache folders; the rest is the app's own data.
                guard parts.count > 4, part(3) == "Data" else { return .doubt("An app's own data") }
                if part(4) == "tmp" { return .junk(.temporary) }
                if part(4) == "Library", part(5) == "Caches", parts.count > 6 { return .junk(.cache) }
                return .doubt("An app's own data")
            case "Developer":
                return developer(parts)
            case "Application Support":
                return applicationSupport(parts)
            default:
                return .doubt("Not on the list AeroClean can vouch for")
            }
        }

        switch first {
        case ".npm":
            switch part(1) {
            case "_cacache", "_prebuilds": return .junk(.downloadCache)
            case "_logs": return .junk(.logs)
            default: return .doubt("npm's own settings")
            }
        case ".cargo":
            return part(1) == "registry" && part(2) == "cache" ? .junk(.downloadCache) : .doubt("Rust's installed tools")
        case ".cache":
            guard let tool = part(1) else { return .doubt("A cache folder holding tools") }
            return Self.downloadCaches.contains(tool) ? .junk(.downloadCache) : .doubt("Some tools keep programs here")
        case ".expo":
            if let kind = part(1), kind == "expo-go" || kind.hasSuffix("-cache") { return .junk(.downloadCache) }
            return .doubt("Expo's own settings")
        case ".config":
            return part(1) == "gcloud" && part(2) == "logs" ? .junk(.logs) : .doubt("Settings")
        case ".lunarclient":
            if part(1) == "game-cache" || part(1) == "launcher-cache" { return .junk(.cache) }
            if parts.contains("logs") { return .junk(.logs) }
            return .doubt("Game files")
        case ".cursor":
            // only folders named publisher.name-version; extensions.json and friends stay.
            guard part(1) == "extensions", let folder = part(2), parts.count == 3,
                  folder.range(of: #"^[A-Za-z0-9-]+\.[A-Za-z0-9-]+-\d+\.\d+"#, options: .regularExpression) != nil
            else { return .doubt("Cursor's settings") }
            if liveCursorExtensions.contains(folder) { return .doubt("An extension Cursor still loads") }
            // junk only when cursor says so, or a newer version of the same extension is loaded.
            let id = Self.extensionID(folder)
            let replaced = liveCursorExtensions.contains { Self.extensionID($0) == id && $0 != folder }
            return obsoleteCursorExtensions.contains(folder) || replaced ? .junk(.oldExtension) : .doubt("An extension Cursor may still use")
        default:
            if name.hasPrefix(".zcompdump") { return .junk(.cache) }
            return .doubt("Not on the list AeroClean can vouch for")
        }
    }

    private func developer(_ parts: [String]) -> JunkVerdict {
        func part(_ index: Int) -> String? { index < parts.count ? parts[index] : nil }
        if part(2) == "Xcode" {
            if part(3) == "DerivedData", parts.count > 4 { return .junk(.buildCache) }
            if part(3) == "UserData", part(4) == "IB Support" { return .junk(.cache) }
            return .doubt("Xcode's own data")
        }
        // a simulator device: only its caches, logs and tmp. its system assets and app data stay.
        if part(2) == "CoreSimulator", part(3) == "Devices", part(5) == "data" {
            let rest = Array(parts.dropFirst(6))
            if rest.starts(with: ["Library", "Caches"]), rest.count > 2 { return .junk(.cache) }
            if rest.starts(with: ["var", "db", "diagnostics"]) || rest.starts(with: ["var", "db", "uuidtext"]) { return .junk(.logs) }
            if rest.first == "tmp", rest.count > 1 { return .junk(.temporary) }
            return .doubt("Part of a simulator's own system")
        }
        return .doubt("Developer tools' own data")
    }

    private func applicationSupport(_ parts: [String]) -> JunkVerdict {
        func part(_ index: Int) -> String? { index < parts.count ? parts[index] : nil }
        guard let app = part(2), let inner = part(3) else { return .doubt("An app's own data") }
        if app == "Adobe", inner == "Common", part(4) == "Media Cache Files" || part(4) == "Media Cache" {
            return .junk(.cache)
        }
        if app == "Google", inner == "GoogleUpdater" {
            if part(4) == "crx_cache" { return .junk(.downloadCache) }
            if let file = part(4), file.hasSuffix(".old") || file.hasSuffix(".log") { return .junk(.logs) }
            return .doubt("Chrome's updater")
        }
        if app == "CrashReporter" { return .junk(.logs) }
        if Self.rebuiltOnLaunch.contains(inner) { return .junk(.cache) }
        if inner == "logs" || inner == "Logs" || inner == "Crashpad" { return .junk(.logs) }
        return .doubt("An app's own data")
    }

    // MARK: lookups

    static let launchServicesKnows: @Sendable (String) -> Bool = { bundle in
        guard let url = LSCopyApplicationURLsForBundleIdentifier(bundle as CFString, nil)?.takeRetainedValue() as? [URL] else { return false }
        return !url.isEmpty
    }

    /// "publisher.name" from "publisher.name-1.2.3-darwin-arm64".
    static func extensionID(_ folder: String) -> String {
        guard let range = folder.range(of: #"-\d+\."#, options: .regularExpression) else { return folder }
        return String(folder[..<range.lowerBound])
    }

    static func cursorObsolete(home: String) -> Set<String> {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".cursor/extensions/.obsolete")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(entries.filter { ($0.value as? Bool) == true }.keys)
    }

    /// folders listed in ~/.cursor/extensions/extensions.json, which cursor loads.
    static func cursorExtensions(home: String) -> Set<String> {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".cursor/extensions/extensions.json")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return Set(entries.compactMap { entry in
            (entry["relativeLocation"] as? String) ?? ((entry["location"] as? [String: Any])?["path"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
        })
    }
}

/// apps that must be closed before their files go. matched by path, so caches of an app
/// are never pulled out from under it.
public enum AppOwners {
    public struct Owner: Sendable {
        public let label: String
        /// bundle id prefixes that count as this app running.
        public let bundles: [String]
    }

    public static func owners(of path: String) -> [Owner] {
        var owners: [Owner] = []
        func has(_ fragment: String) -> Bool { path.contains(fragment) }
        if has("/Adobe/") || has("/com.adobe.") || has("/Adobe ") { owners.append(Owner(label: "Adobe apps", bundles: ["com.adobe."])) }
        if has("/CoreSimulator/") { owners.append(Owner(label: "Simulator", bundles: ["com.apple.iphonesimulator"])) }
        if has("/Developer/Xcode/") { owners.append(Owner(label: "Xcode", bundles: ["com.apple.dt.Xcode"])) }
        if has("/.cursor/") || has("/Cursor/") { owners.append(Owner(label: "Cursor", bundles: ["com.todesktop.230313mzl4w4u92"])) }
        if has("/Google/Chrome") || has("/com.google.Chrome") { owners.append(Owner(label: "Chrome", bundles: ["com.google.Chrome"])) }
        if has("/.lunarclient/") || has("/lunarclient/") { owners.append(Owner(label: "Lunar Client", bundles: ["com.moonsworth.client"])) }
        if has("/Steam/") { owners.append(Owner(label: "Steam", bundles: ["com.valvesoftware.steam"])) }
        if has("/Firefox/") { owners.append(Owner(label: "Firefox", bundles: ["org.mozilla.firefox"])) }
        if has("/zoom.us") || has("/us.zoom.") { owners.append(Owner(label: "Zoom", bundles: ["us.zoom.xos"])) }
        return owners
    }
}
