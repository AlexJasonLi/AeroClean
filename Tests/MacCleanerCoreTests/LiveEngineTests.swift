import Foundation
import Testing
@testable import MacCleanerCore

/// runs each engine against this mac, read-only. off by default:
/// MACCLEANER_LIVE=1 swift test --filter LiveEngineTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACCLEANER_LIVE"] == "1"))
struct LiveEngineTests {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let policy = SafetyPolicy()

    @Test func moleLastPreviewParsesAndPassesThePolicy() throws {
        let preview = try #require(JunkEngine().lastPreview(), "run mo clean --dry-run once first")
        let total = preview.items.reduce(0) { $0 + ($1.bytes ?? 0) }
        let refused = preview.items.filter { !policy.verdict(for: $0.url).isAllowed }
        print("junk: \(preview.items.count) items, \(total) bytes, \(refused.count) refused, sections \(Set(preview.items.map(\.section)).sorted())")
        for item in refused.prefix(10) { print("  refused: \(item.url.path) -> \(policy.verdict(for: item.url))") }
        #expect(!preview.items.isEmpty)
    }

    @Test func indexesTheHomeFolderQuickly() async throws {
        let index = FastScanner.scan(roots: [home])
        print("index: \(index.totalFiles) files, \(index.totalBytes) bytes, \(index.files.count) big files in \(index.duration) s")
        #expect(index.totalFiles > 0)
        #expect(index.duration < 60)
        let candidates = DuplicateEngine.candidates(in: index, home: home.path, minimumBytes: 10_000_000)
        let groups = try await DuplicateEngine().scan(candidates: candidates, minimumBytes: 10_000_000)
        print("duplicates: \(candidates.count) candidates, \(groups.count) groups")
        #expect(groups.allSatisfy { $0.copies.count > 1 })
        let volumes = await SystemProbe.volumes()
        print("volumes: swap \(volumes.swap), preboot \(volumes.preboot), snapshots \(volumes.localSnapshots)")
        #expect(volumes.preboot > 0)
    }

    @Test func diskStatusReads() throws {
        let disk = try #require(DiskStatus.current())
        print("disk: \(disk.availableBytes) available of \(disk.totalBytes), trash readable=\(TrashService.size() != nil)")
        #expect(disk.totalBytes > disk.availableBytes)
    }
}

final class LockedList<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func append(_ item: T) { lock.withLock { storage.append(item) } }
    var items: [T] { lock.withLock { storage } }
}
