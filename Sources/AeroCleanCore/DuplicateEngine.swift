import Foundation

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public struct Copy: Identifiable, Hashable, Sendable {
        public var id: String { url.path }
        public let url: URL
        public let created: Date?
        public let modified: Date?
    }

    public var id: String { hash }
    public let hash: String
    /// size of one copy.
    public let bytes: Int64
    public let copies: [Copy]

    public init(hash: String, bytes: Int64, copies: [Copy]) {
        self.hash = hash
        self.bytes = bytes
        self.copies = copies
    }

    /// space freed by keeping one copy.
    public var redundantBytes: Int64 { bytes * Int64(max(copies.count - 1, 0)) }

    /// the copy to keep when selecting extras automatically: the oldest, then the shortest path.
    public var suggestedKeeper: Copy? {
        copies.min { a, b in
            switch (a.created, b.created) {
            case let (x?, y?) where x != y: return x < y
            default: return a.url.path.count < b.url.path.count
            }
        }
    }
}

/// finds identical files with fclones. it only groups; removal goes through the trasher.
public struct DuplicateEngine: Sendable {
    public let home: URL
    public let policy: SafetyPolicy

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        policy = SafetyPolicy(home: home)
    }

    public func scan(minimumBytes: Int64) async throws -> [DuplicateGroup] {
        guard let fclones = Tool.fclones.location else { throw MissingTool(tool: .fclones) }
        var arguments = ["-q", "group", home.path, "--min", "\(minimumBytes)B", "--format", "json"]
        // fclones skips hidden files and honours .gitignore by default. app data in ~/Library
        // and dependency folders are left out too: identical copies there are expected, and
        // removing one breaks the project that installed it.
        let excluded = ["Library", ".Trash"].map { home.appendingPathComponent($0).path + "/**" }
            + SafetyPolicy.mediaLibraryExtensions.map { "**/*.\($0)/**" }
            + Self.dependencyFolders.map { "**/\($0)/**" }
        for pattern in excluded { arguments += ["--exclude", pattern] }

        let result = try await ProcessRunner.run(fclones, arguments)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ProcessFailure(tool: "fclones", status: result.status, stderr: result.stderr)
        }
        return try Self.decode(result.stdout, policy: policy)
    }

    /// hands fclones a list of files instead of letting it walk the disk. the index already
    /// knows every size, so only files that share a length with another file are passed.
    public func scan(candidates: [String], minimumBytes: Int64) async throws -> [DuplicateGroup] {
        guard let fclones = Tool.fclones.location else { throw MissingTool(tool: .fclones) }
        guard candidates.count > 1 else { return [] }
        let input = Data(candidates.joined(separator: "\n").utf8)
        let result = try await ProcessRunner.run(
            fclones, ["-q", "group", "--stdin", "--min", "\(minimumBytes)B", "--format", "json"], input: input
        )
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ProcessFailure(tool: "fclones", status: result.status, stderr: result.stderr)
        }
        return try Self.decode(result.stdout, policy: policy)
    }

    /// files worth comparing: same length as another file, outside app data, hidden and dependency folders.
    public static func candidates(in index: DiskIndex, home: String, minimumBytes: Int64) -> [String] {
        let skipped = Set(dependencyFolders + ["Library", ".Trash"])
        var byLength: [Int64: [String]] = [:]
        var folderOK: [Int32: Bool] = [:]
        func allowed(_ folder: Int32) -> Bool {
            if let known = folderOK[folder] { return known }
            let path = index.path(of: folder)
            var ok = path == home || path.hasPrefix(home + "/")
            if ok {
                let parts = path.dropFirst(home.count).split(separator: "/")
                if let first = parts.first, first == "Library" || first == ".Trash" { ok = false }
                if parts.contains(where: { $0.hasPrefix(".") || skipped.contains(String($0)) }) { ok = false }
                if parts.contains(where: { SafetyPolicy.mediaLibraryExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) { ok = false }
            }
            folderOK[folder] = ok
            return ok
        }
        for file in index.files where file.length >= minimumBytes && !file.name.hasPrefix(".") && allowed(file.folder) {
            byLength[file.length, default: []].append(index.path(of: file))
        }
        return byLength.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    static let dependencyFolders = [
        "node_modules", "app.asar.unpacked", ".venv", "venv", "site-packages", "Pods",
        ".build", "DerivedData", ".next", ".gradle",
    ]

    static func decode(_ data: Data, policy: SafetyPolicy) throws -> [DuplicateGroup] {
        struct Output: Decodable { let groups: [Group] }
        struct Group: Decodable {
            let file_len: Int64
            let file_hash: String
            let files: [String]
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        return output.groups.compactMap { group in
            let copies = group.files.compactMap { path -> DuplicateGroup.Copy? in
                let url = URL(fileURLWithPath: path)
                guard policy.verdict(for: url).isAllowed else { return nil }
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                return .init(url: url, created: values?.creationDate, modified: values?.contentModificationDate)
            }
            guard copies.count > 1 else { return nil }
            return DuplicateGroup(hash: group.file_hash, bytes: group.file_len, copies: copies)
        }
        .sorted { $0.redundantBytes > $1.redundantBytes }
    }
}
