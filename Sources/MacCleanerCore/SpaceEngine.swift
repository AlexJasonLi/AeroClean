import Foundation

/// one entry of a folder, sized by mole's analyzer.
public struct SpaceEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bytes: Int64
    public let isDirectory: Bool
    /// mole knows this folder is safe to clear (caches, build output).
    public let isCleanable: Bool
    /// the scan could not read everything inside, so the size is a lower bound.
    public let isPartial: Bool
    public let lastAccess: Date?
}

public struct SpaceListing: Sendable {
    public let url: URL
    public let entries: [SpaceEntry]
    public let totalBytes: Int64
    public let isPartial: Bool

    public init(url: URL, entries: [SpaceEntry], totalBytes: Int64, isPartial: Bool) {
        self.url = url
        self.entries = entries
        self.totalBytes = totalBytes
        self.isPartial = isPartial
    }
}

/// wraps `mo analyze --json <folder>`.
public struct SpaceEngine: Sendable {
    public init() {}

    public func list(_ folder: URL) async throws -> SpaceListing {
        guard let mole = Tool.mole.location else { throw MissingTool(tool: .mole) }
        let result = try await ProcessRunner.run(mole, ["analyze", "--json", folder.path])
        try Task.checkCancellation()
        guard result.status == 0 else {
            throw ProcessFailure(tool: "mo analyze", status: result.status, stderr: result.stderr)
        }
        return try Self.decode(result.stdout)
    }

    static func decode(_ data: Data) throws -> SpaceListing {
        struct Output: Decodable {
            let scan_status: String
            let path: String
            let entries: [Entry]
            let total_size: Int64
        }
        struct Entry: Decodable {
            let scan_status: String
            let name: String
            let path: String
            let size: Int64
            let is_dir: Bool
            let cleanable: Bool?
            let last_access: String?
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        let dates = ISO8601DateFormatter()
        let entries = output.entries.map { entry in
            SpaceEntry(
                url: URL(fileURLWithPath: entry.path),
                name: entry.name,
                bytes: max(entry.size, 0),
                isDirectory: entry.is_dir,
                isCleanable: entry.cleanable ?? false,
                isPartial: entry.scan_status != "complete",
                lastAccess: entry.last_access.flatMap { dates.date(from: $0) }
            )
        }
        return SpaceListing(
            url: URL(fileURLWithPath: output.path),
            entries: entries,
            totalBytes: output.total_size,
            isPartial: output.scan_status != "complete"
        )
    }
}
