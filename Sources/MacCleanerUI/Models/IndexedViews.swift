import AppKit
import MacCleanerCore
import Observation

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// "~/Downloads/Clips" instead of the full path.
    static func location(_ url: URL, home: String) -> String { location(url.standardizedFileURL.path, home: home) }

    static func location(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func relative(_ date: Date?) -> String {
        guard let date, date > Date(timeIntervalSince1970: 86_400) else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func items(_ value: Int) -> String { value == 1 ? "1 item" : "\(count(value)) items" }
}

/// finder icons, cached by path.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func file(_ path: String) -> NSImage {
        image(for: path) { NSWorkspace.shared.icon(forFile: path) }
    }

    /// the app's icon when `owner` is an installed app's bundle id or name.
    static func owner(_ owner: String, fallback: String?) -> NSImage {
        image(for: "owner:" + owner) {
            if owner.split(separator: ".").count >= 3, !owner.contains(" "),
               let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner)
            {
                return NSWorkspace.shared.icon(forFile: app.path)
            }
            for folder in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
                let candidate = folder + "/" + owner + ".app"
                if FileManager.default.fileExists(atPath: candidate) { return NSWorkspace.shared.icon(forFile: candidate) }
            }
            if let fallback { return NSWorkspace.shared.icon(forFile: fallback) }
            return NSWorkspace.shared.icon(for: .folder)
        }
    }

    /// an app's display name for a bundle id, if it is installed.
    static func appName(_ owner: String) -> String? {
        guard owner.split(separator: ".").count >= 3, !owner.contains(" "),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner)
        else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func image(for key: String, make: () -> NSImage) -> NSImage {
        if let cached = cache[key] { return cached }
        let made = make()
        made.size = NSSize(width: 32, height: 32)
        cache[key] = made
        return made
    }
}

// MARK: large files

struct LargeRow: Identifiable, Hashable {
    let path: String
    let name: String
    let location: String
    let bytes: Int64
    let modified: Date
    var id: String { path }
}

@MainActor @Observable
final class LargeFilesModel {
    static let thresholds: [Int64] = [50, 100, 250, 1000].map { $0 * 1_000_000 }

    var minimumBytes: Int64 = 100_000_000
    var includeLibrary = false
    var search = ""
    var checked: Set<String> = []
    private var policy = SafetyPolicy()

    func rows(_ model: IndexModel) -> [LargeRow] {
        guard let index = model.index else { return [] }
        let home = model.home
        let library = home + "/Library/"
        let query = search.trimmingCharacters(in: .whitespaces)
        var rows: [LargeRow] = []
        for file in index.files where file.allocated >= minimumBytes {
            let path = index.path(of: file)
            guard path.hasPrefix(home + "/"), includeLibrary || !path.hasPrefix(library) else { continue }
            guard query.isEmpty || path.localizedCaseInsensitiveContains(query) else { continue }
            guard !model.isRemoved(path), policy.verdict(for: URL(fileURLWithPath: path)).isAllowed else { continue }
            rows.append(LargeRow(
                path: path, name: file.name,
                location: Format.location((path as NSString).deletingLastPathComponent, home: home),
                bytes: file.allocated, modified: Date(timeIntervalSince1970: file.modified)
            ))
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }

    func checkedItems(_ rows: [LargeRow]) -> [RemovalItem] {
        rows.filter { checked.contains($0.id) }.map { RemovalItem(url: URL(fileURLWithPath: $0.path), bytes: $0.bytes) }
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        checked = checked.filter { !Trasher.covers(paths, $0) }
    }
}

// MARK: space

struct SpaceRow: Identifiable, Hashable {
    enum Kind: Hashable { case folder(Int32), file, smallFiles }
    let id: String
    let name: String
    let path: String
    let bytes: Int64
    let kind: Kind
    let detail: String
    let refusal: String?
    let rebuildable: Bool
}

@MainActor @Observable
final class SpaceModel {
    var folder: Int32?
    var checked: Set<String> = []
    private let policy = SafetyPolicy()

    /// folders that hold rebuildable output: caches and build products.
    static let rebuildableNames: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", "DerivedData", "__pycache__", ".pytest_cache",
        ".mypy_cache", ".ruff_cache", ".gradle", "Caches", ".cache", "target", ".build", "build", "dist", "Pods",
    ]

    func current(_ model: IndexModel) -> Int32? { folder ?? model.homeNode }

    func open(_ node: Int32) {
        folder = node
        checked = []
    }

    func breadcrumbs(_ model: IndexModel) -> [Int32] {
        guard let index = model.index, var node = current(model), let home = model.homeNode else { return [] }
        var trail = [node]
        while node != home, index.parents[Int(node)] >= 0 {
            node = index.parents[Int(node)]
            trail.insert(node, at: 0)
        }
        return trail
    }

    func rows(_ model: IndexModel) -> [SpaceRow] {
        guard let index = model.index, let node = current(model) else { return [] }
        var rows: [SpaceRow] = []
        for child in model.biggestChildren(of: node) {
            let path = index.path(of: child)
            guard !model.isRemoved(path) else { continue }
            let name = index.names[Int(child)]
            rows.append(SpaceRow(
                id: path, name: name, path: path, bytes: model.total(child), kind: .folder(child),
                detail: Format.count(Int(index.fileCounts[Int(child)])) + " files",
                refusal: refusal(path), rebuildable: Self.rebuildableNames.contains(name)
            ))
        }
        for position in model.filesByFolder[node] ?? [] {
            let file = index.files[position]
            let path = index.path(of: file)
            guard !model.isRemoved(path) else { continue }
            rows.append(SpaceRow(
                id: path, name: file.name, path: path, bytes: file.allocated, kind: .file,
                detail: Format.relative(Date(timeIntervalSince1970: file.modified)),
                refusal: refusal(path), rebuildable: false
            ))
        }
        let small = index.smallBytes[Int(node)]
        if small > 0 {
            rows.append(SpaceRow(
                id: "small:\(node)", name: "\(Format.count(Int(index.smallCounts[Int(node)]))) small files", path: index.path(of: node),
                bytes: small, kind: .smallFiles, detail: "under 1 MB each", refusal: "Open the folder in Finder to pick small files", rebuildable: false
            ))
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }

    private func refusal(_ path: String) -> String? {
        if case .refused(let reason) = policy.verdict(for: URL(fileURLWithPath: path)) { return reason }
        return nil
    }

    func checkedItems(_ rows: [SpaceRow]) -> [RemovalItem] {
        rows.filter { checked.contains($0.id) && $0.kind != .smallFiles }
            .map { RemovalItem(url: URL(fileURLWithPath: $0.path), bytes: $0.bytes) }
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        checked = checked.filter { !Trasher.covers(paths, $0) }
    }
}
