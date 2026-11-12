import Foundation

/// decides whether a path may be moved to the trash. pure path logic, no disk access,
/// so every rule is testable against a fake home folder.
public struct SafetyPolicy: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case refused(String)

        public var isAllowed: Bool { self == .allowed }
    }

    /// the home folder with symlinks resolved, no trailing slash.
    public let homePath: String

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homePath = Self.canonicalPath(home)
    }

    // top-level folders of the home folder that are never removed as a whole.
    static let protectedTopLevel: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies",
        "Music", "Pictures", "Public", "Sites", ".Trash",
        ".config", ".local", ".ssh", ".gnupg", ".aws", ".kube", ".docker",
    ]

    // top-level folders whose contents are never touched: credentials and the trash itself.
    static let sealedTopLevel: Set<String> = [".Trash", ".ssh", ".gnupg", ".aws", ".kube"]

    // folders under ~/Library whose contents are never touched: removal there loses
    // data that is not a cache, or syncs the removal to other devices.
    static let sealedInLibrary: Set<String> = [
        "Keychains", "Mobile Documents", "CloudStorage", "Mail", "Messages", "Accounts",
        "Photos", "Passes", "Sharing", "PersonalizationPortrait", "Safari",
    ]

    // packages managed by their apps. never removed, and nothing inside them is.
    static let mediaLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx",
    ]

    // code bundles whose insides are never removed piece by piece. cache folders are often
    // named after bundle ids ("com.example.app"), so these only count when the folder
    // really is a bundle on disk.
    static let codeBundleExtensions: Set<String> = [
        "app", "framework", "appex", "bundle", "plugin", "kext", "xpc",
    ]

    public func verdict(for url: URL) -> Verdict {
        guard url.isFileURL else { return .refused("Not a file on this Mac") }
        let path = Self.canonicalPath(url)
        guard path.hasPrefix(homePath + "/") else {
            return .refused("Outside your home folder")
        }
        let relative = path.dropFirst(homePath.count + 1)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return .refused("This is your home folder") }

        if parts.count == 1, Self.protectedTopLevel.contains(first) {
            return .refused("Standard folder, remove what is inside it instead")
        }
        if Self.sealedTopLevel.contains(first) {
            return first == ".Trash" ? .refused("Already in the Trash") : .refused("Holds credentials")
        }
        if first == "Library" {
            if parts.count == 2 {
                return .refused("Part of your Library, remove what is inside it instead")
            }
            if parts.count > 2, Self.sealedInLibrary.contains(parts[1]) {
                return .refused("\(parts[1]) data is never removed by MacCleaner")
            }
        }
        if parts.contains(".git") {
            return .refused("Git history")
        }
        let leafExtension = (parts.last! as NSString).pathExtension.lowercased()
        if Self.mediaLibraryExtensions.contains(leafExtension) {
            return .refused("Media library, manage it in its own app")
        }
        var ancestorPath = homePath
        for ancestor in parts.dropLast() {
            ancestorPath += "/" + ancestor
            let ext = (ancestor as NSString).pathExtension.lowercased()
            if Self.mediaLibraryExtensions.contains(ext) {
                return .refused("Inside \(ancestor), manage it in its own app")
            }
            if Self.codeBundleExtensions.contains(ext), Self.isCodeBundle(ancestorPath) {
                return .refused("Inside \(ancestor), remove the whole item in Finder")
            }
        }
        return .allowed
    }

    static func isCodeBundle(_ path: String) -> Bool {
        let manager = FileManager.default
        return ["Contents/Info.plist", "Info.plist", "Resources/Info.plist"].contains {
            manager.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
    }

    /// absolute, standardized path with the parent's symlinks resolved. the leaf itself is
    /// not resolved, so a symlink is judged (and trashed) as the link, not its target.
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let leaf = standardized.lastPathComponent
        let parent = standardized.deletingLastPathComponent()
        if standardized.path == "/" { return "/" }
        let resolvedParent = parent.resolvingSymlinksInPath().path
        let joined = (resolvedParent as NSString).appendingPathComponent(leaf)
        return joined.count > 1 && joined.hasSuffix("/") ? String(joined.dropLast()) : joined
    }
}
