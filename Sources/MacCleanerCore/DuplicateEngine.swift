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
        // fclones skips hidden files and honours .gitignore by default, which keeps
        // dependency folders and tool caches out. app data in ~/Library is left alone too.
        let excluded = ["Library", ".Trash"].map { home.appendingPathComponent($0).path + "/**" }
            + SafetyPolicy.mediaLibraryExtensions.map { "**/*.\($0)/**" }
        for pattern in excluded { arguments += ["--exclude", pattern] }

        let result = try await ProcessRunner.run(fclones, arguments)
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ProcessFailure(tool: "fclones", status: result.status, stderr: result.stderr)
        }
        return try Self.decode(result.stdout, policy: policy)
    }

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
