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

    @Test func junkRulesOnMolesList() throws {
        let preview = try #require(JunkEngine().lastPreview())
        let rules = JunkRules()
        var kept: [String: (Int, Int64)] = [:]
        var doubts: [String: (Int, Int64, String)] = [:]
        for item in preview.items {
            let bytes = item.bytes ?? 0
            switch rules.classify(item.url.path) {
            case .junk(let kind):
                let old = kept[kind.title] ?? (0, 0)
                kept[kind.title] = (old.0 + 1, old.1 + bytes)
            case .doubt(let reason):
                let old = doubts[reason] ?? (0, 0, item.url.path)
                doubts[reason] = (old.0 + 1, old.1 + bytes, old.2)
            }
        }
        for (title, value) in kept.sorted(by: { $0.value.1 > $1.value.1 }) {
            print(String(format: "KEEP  %8.1f MB  %5d  %@", Double(value.1) / 1e6, value.0, title))
        }
        for (reason, value) in doubts.sorted(by: { $0.value.1 > $1.value.1 }) {
            print(String(format: "DOUBT %8.1f MB  %5d  %@  e.g. %@", Double(value.1) / 1e6, value.0, reason, value.2))
        }
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
