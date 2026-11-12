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

    @Test func fdFindsLargeFiles() async throws {
        let found = LockedList<LargeFile>()
        let count = try await LargeFileEngine().scan(minimumBytes: 500_000_000, includeLibrary: false) { found.append($0) }
        let files = found.items.sorted { $0.bytes > $1.bytes }
        print("large: \(count) files over 500 MB")
        for file in files.prefix(5) { print("  \(file.bytes) \(file.kind) \(file.url.path) opened=\(String(describing: file.lastOpened))") }
        #expect(count == files.count)
        #expect(files.allSatisfy { $0.bytes >= 500_000_000 && policy.verdict(for: $0.url).isAllowed })
    }

    @Test func fclonesFindsDuplicates() async throws {
        let groups = try await DuplicateEngine().scan(minimumBytes: 10_000_000)
        print("duplicates: \(groups.count) groups, \(groups.reduce(0) { $0 + $1.redundantBytes }) redundant bytes")
        for group in groups.prefix(3) { print("  \(group.copies.count)x \(group.bytes) \(group.copies.map(\.url.lastPathComponent))") }
        #expect(groups.allSatisfy { $0.copies.count > 1 })
        #expect(!groups.flatMap(\.copies).contains { $0.url.path.contains("/Library/") })
    }

    @Test func moleMeasuresAFolder() async throws {
        let listing = try await SpaceEngine().list(home.appendingPathComponent("Downloads"))
        print("space: ~/Downloads \(listing.totalBytes) bytes, \(listing.entries.count) entries, partial=\(listing.isPartial)")
        #expect(listing.totalBytes > 0)
        #expect(listing.entries.allSatisfy { $0.url.path.hasPrefix(home.path + "/Downloads/") })
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
