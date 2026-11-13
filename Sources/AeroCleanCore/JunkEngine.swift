import Foundation

/// one path from mole's cleanup preview.
public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// nil when mole could not measure it.
    public let bytes: Int64?
    /// mole's section, e.g. "Developer tools".
    public let section: String
    /// the app or tool the path belongs to, e.g. "Homebrew" or "com.apple.geod".
    public let owner: String
    public let itemCount: Int
}

/// parses ~/.config/mole/clean-list.txt, written by `mo clean --dry-run`.
///
/// format, one candidate per line under `=== section ===` headers:
///     /path  # 2.66GB, 55 items
///     /path  # 4KB, counted under /ancestor      (already inside another row)
///     /path  # size unknown
public enum MoleCleanList {
    public static func parse(_ text: String, home: String) -> [JunkItem] {
        var section = "Other"
        var items: [JunkItem] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                section = String(line.dropFirst(4).dropLast(4))
                continue
            }
            guard line.hasPrefix("/"), let marker = line.range(of: "  # ") else { continue }
            let path = String(line[..<marker.lowerBound])
            let note = String(line[marker.upperBound...])
            if note.contains("counted under ") { continue }
            if path == home + "/.Trash" || path.hasPrefix(home + "/.Trash/") { continue }

            let fields = note.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let bytes = fields.first.flatMap { parseSize($0) }
            if bytes == 0 { continue }
            var count = 1
            for field in fields.dropFirst() where field.hasSuffix(" items") {
                count = Int(field.dropLast(6)) ?? 1
            }
            items.append(JunkItem(
                url: URL(fileURLWithPath: path),
                bytes: bytes,
                section: section,
                owner: owner(of: path, home: home),
                itemCount: count
            ))
        }
        return items
    }

    /// mole prints decimal units: 4KB, 135.7MB, 2.66GB.
    static func parseSize(_ text: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count)) else { return nil }
            return Int64((value * scale).rounded())
        }
        return nil
    }

    /// names the app or tool a path belongs to, for grouping.
    public static func owner(of path: String, home: String) -> String {
        guard path.hasPrefix(home + "/") else { return (path as NSString).lastPathComponent }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first else { return "Home" }
        func part(_ index: Int) -> String? { index < parts.count ? parts[index] : nil }

        if first == "Library", let area = part(1) {
            switch area {
            case "Caches", "Logs", "Application Support", "Containers", "Group Containers",
                 "HTTPStorages", "WebKit", "Cookies":
                return part(2).map(stripExtension) ?? area
            case "Saved Application State":
                return "Saved app states"
            case "Developer":
                switch part(2) {
                case "CoreSimulator": return "iOS Simulators"
                case "Xcode": return "Xcode"
                default: return part(2) ?? "Developer"
                }
            default:
                return area
            }
        }
        if first.hasPrefix(".") {
            // ~/.cache/<tool> names the tool; ~/.npm names npm.
            if first == ".cache", let tool = part(1) { return tool }
            return String(first.dropFirst())
        }
        return first
    }

    private static func stripExtension(_ name: String) -> String {
        for suffix in [".savedState", ".log"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

/// runs mole's preview. mole decides what is safe; it never deletes anything in dry-run mode.
public struct JunkEngine: Sendable {
    public let home: String
    public var listURL: URL { URL(fileURLWithPath: home).appendingPathComponent(".config/mole/clean-list.txt") }

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = home
    }

    /// the preview mole wrote last time, if any, with when it was written.
    public func lastPreview() -> (items: [JunkItem], date: Date)? {
        guard let text = try? String(contentsOf: listURL, encoding: .utf8),
              let date = (try? FileManager.default.attributesOfItem(atPath: listURL.path))?[.modificationDate] as? Date
        else { return nil }
        return (MoleCleanList.parse(text, home: home), date)
    }

    /// `progress` gets each section name as mole reaches it.
    public func scan(progress: @escaping @Sendable (String) -> Void) async throws -> (items: [JunkItem], date: Date) {
        guard let mole = Tool.mole.location else { throw MissingTool(tool: .mole) }
        let started = Date()
        let result = try await ProcessRunner.run(mole, ["clean", "--dry-run"]) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("➤ ") { progress(String(trimmed.dropFirst(2))) }
        }
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ProcessFailure(tool: "mo clean --dry-run", status: result.status, stderr: result.stderr)
        }
        guard let preview = lastPreview(), preview.date >= started.addingTimeInterval(-1) else {
            // mole prints "nothing to clean" without rewriting the list.
            return ([], Date())
        }
        return preview
    }
}

public struct MissingTool: LocalizedError, Sendable {
    public let tool: Tool
    public var errorDescription: String? { "\(tool.rawValue) is not installed. Run: brew install \(tool.formula)" }
}
