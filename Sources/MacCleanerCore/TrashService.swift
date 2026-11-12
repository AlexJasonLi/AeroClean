import Foundation

public struct DiskStatus: Sendable, Equatable {
    public let totalBytes: Int64
    /// what finder calls available: free space plus purgeable space macOS can reclaim.
    public let availableBytes: Int64

    public var usedFraction: Double {
        totalBytes > 0 ? Double(totalBytes - availableBytes) / Double(totalBytes) : 0
    }

    public static func current(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> DiskStatus? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskStatus(totalBytes: Int64(total), availableBytes: available)
    }
}

/// the trash itself: how big it is, and emptying it through the finder.
public enum TrashService {
    public static var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    /// size of the trash on this disk. the finder also empties trashes on other volumes.
    /// nil when macOS does not let the app read the trash (needs full disk access).
    public static func size() -> Int64? {
        let manager = FileManager.default
        guard (try? manager.contentsOfDirectory(atPath: trashURL.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = manager.enumerator(at: trashURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return nil }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// asks the finder to empty the trash, the same as Finder > Empty Trash.
    /// the first time, macOS asks whether MacCleaner may control the finder.
    public static func empty() async throws {
        let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
        // the default apple event timeout is two minutes; a big trash takes longer.
        let script = "with timeout of 3600 seconds\ntell application \"Finder\" to empty trash\nend timeout"
        let result = try await ProcessRunner.run(osascript, ["-e", script])
        guard result.status == 0 else {
            if result.stderr.contains("-1743") {
                throw EmptyTrashError.notAllowed
            }
            throw ProcessFailure(tool: "Finder", status: result.status, stderr: result.stderr)
        }
    }
}

public enum EmptyTrashError: LocalizedError, Sendable {
    case notAllowed

    public var errorDescription: String? {
        "MacCleaner is not allowed to control the Finder. Turn it on in System Settings > Privacy & Security > Automation, or empty the Trash from the Finder."
    }
}
