import Foundation

public struct TrashRequest: Hashable, Sendable {
    public let url: URL
    /// size measured when the item was found, used for the freed-space total.
    public let bytes: Int64

    public init(url: URL, bytes: Int64) {
        self.url = url
        self.bytes = bytes
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

    public var bytesMoved: Int64 { moved.reduce(0) { $0 + $1.bytes } }
    public var movedPaths: Set<String> { Set(moved.map { $0.original.path }) }
}

/// the only code that removes user files. every request is checked against the
/// safety policy and must still exist; removal means moving to the trash.
public struct Trasher: Sendable {
    public let policy: SafetyPolicy
    public let log: RemovalLog?

    public init(policy: SafetyPolicy = SafetyPolicy(), log: RemovalLog? = RemovalLog()) {
        self.policy = policy
        self.log = log
    }

    /// drops requests that sit inside another request, so a folder and its contents
    /// are not counted twice.
    public static func collapse(_ requests: [TrashRequest]) -> [TrashRequest] {
        let byPath = Dictionary(requests.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        let paths = Set(byPath.keys)
        let kept = byPath.keys.sorted().filter { path in
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.count > 1 {
                if paths.contains(ancestor) { return false }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return true
        }
        return kept.compactMap { byPath[$0] }
    }

    /// checks without touching the disk beyond existence.
    public func preflight(_ request: TrashRequest) -> String? {
        if case .refused(let reason) = policy.verdict(for: request.url) { return reason }
        // attributesOfItem does not follow a final symlink, so a dangling link still counts.
        let exists = (try? FileManager.default.attributesOfItem(atPath: request.url.path)) != nil
        return exists ? nil : "No longer exists"
    }

    public func trash(_ requests: [TrashRequest]) -> TrashOutcome {
        var outcome = TrashOutcome()
        for request in Self.collapse(requests) {
            if let reason = preflight(request) {
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
