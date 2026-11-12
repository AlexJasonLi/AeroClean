import Foundation

public struct TrashRequest: Hashable, Sendable {
    public let url: URL
    /// size measured when the item was found, used for the freed-space total.
    public let bytes: Int64
    /// for a duplicate: the other copies. at least one of them must still exist, with the
    /// same size, and stay out of the trash, or this copy is kept.
    public let survivors: [URL]

    public init(url: URL, bytes: Int64, survivors: [URL] = []) {
        self.url = url
        self.bytes = bytes
        self.survivors = survivors
    }
}

public struct TrashOutcome: Sendable {
    public struct Moved: Sendable {
        public let original: URL
        public let inTrash: URL?
        public let bytes: Int64
    }

    public struct Failed: Sendable {
        public let url: URL
        public let reason: String
    }

    public var moved: [Moved] = []
    public var failed: [Failed] = []

    public init() {}

    public var bytesMoved: Int64 { moved.reduce(0) { $0 + $1.bytes } }
    public var movedPaths: Set<String> { Set(moved.map { $0.original.standardizedFileURL.path }) }
}

/// the only code that removes user files. every request is checked against the
/// safety policy and must still exist; removal means moving to the trash.
public struct Trasher: Sendable {
    public let policy: SafetyPolicy
    public let log: RemovalLog?
    /// says why an item is in use right now (for example its app is running), or nil.
    public let inUse: (@Sendable (URL) -> String?)?

    public init(policy: SafetyPolicy = SafetyPolicy(), log: RemovalLog? = RemovalLog(), inUse: (@Sendable (URL) -> String?)? = nil) {
        self.policy = policy
        self.log = log
        self.inUse = inUse
    }

    /// drops requests that sit inside another request, so a folder and its contents
    /// are not counted twice.
    public static func collapse(_ requests: [TrashRequest]) -> [TrashRequest] {
        let byPath = Dictionary(requests.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = Set(byPath.keys)
        return byPath.keys.sorted()
            .filter { !isInside($0, anyOf: paths) }
            .compactMap { byPath[$0] }
    }

    /// true when `path` is one of `paths` or sits inside one of them.
    public static func covers(_ paths: Set<String>, _ path: String) -> Bool {
        paths.contains(path) || isInside(path, anyOf: paths)
    }

    private static func isInside(_ path: String, anyOf paths: Set<String>) -> Bool {
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.count > 1 {
            if paths.contains(ancestor) { return true }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return false
    }

    /// every check short of moving the item. `leaving` holds paths already moved or about
    /// to be moved in this batch, which do not count as surviving copies.
    public func preflight(_ request: TrashRequest, leaving: Set<String> = []) -> String? {
        if case .refused(let reason) = policy.verdict(for: request.url) { return reason }
        if let reason = inUse?(request.url) { return reason }
        // attributesOfItem does not follow a final symlink, so a dangling link still counts.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: request.url.path) else {
            return "No longer exists"
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            let report = FolderInspector.inspect(request.url)
            if let library = report.mediaLibraries.first {
                return "Holds a media library (\(library)), manage it in its own app"
            }
        }
        if !request.survivors.isEmpty, !hasSurvivor(request, leaving: leaving) {
            return "Its other copies are gone, so this one was kept"
        }
        return nil
    }

    private func hasSurvivor(_ request: TrashRequest, leaving: Set<String>) -> Bool {
        request.survivors.contains { survivor in
            let path = survivor.standardizedFileURL.path
            guard !Self.covers(leaving, path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == request.bytes
            else { return false }
            return true
        }
    }

    /// `progress` gets (finished, total) after each item.
    public func trash(_ requests: [TrashRequest], progress: (@Sendable (Int, Int) -> Void)? = nil) -> TrashOutcome {
        var outcome = TrashOutcome()
        let batch = Self.collapse(requests)
        let leaving = Set(batch.map { $0.url.standardizedFileURL.path })
        for (index, request) in batch.enumerated() {
            defer { progress?(index + 1, batch.count) }
            if let reason = preflight(request, leaving: leaving) {
                outcome.failed.append(.init(url: request.url, reason: reason))
                continue
            }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: request.url, resultingItemURL: &resulting)
                let inTrash = resulting as URL?
                outcome.moved.append(.init(original: request.url, inTrash: inTrash, bytes: request.bytes))
                log?.record(original: request.url, inTrash: inTrash, bytes: request.bytes)
            } catch {
                outcome.failed.append(.init(url: request.url, reason: Self.describe(error)))
            }
        }
        return outcome
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "Needs an administrator, skipped"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "No longer exists"
            default: break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) || ns.code == Int(EACCES) {
            return "Needs an administrator, skipped"
        }
        return ns.localizedDescription
    }
}

/// append-only record of every removal, so anything can be found in the trash and put back.
public struct RemovalLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacCleaner/removals.log"))
    {
        self.fileURL = fileURL
    }

    public func record(original: URL, inTrash: URL?, bytes: Int64) {
        let line = [
            ISO8601DateFormatter().string(from: Date()),
            String(bytes),
            original.path,
            inTrash?.path ?? "",
        ].joined(separator: "\t") + "\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: Data("date\tbytes\toriginal\tin_trash\n".utf8))
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
