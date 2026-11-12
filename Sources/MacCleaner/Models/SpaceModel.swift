import AppKit
import MacCleanerCore
import Observation

struct SpaceRow: Identifiable, Hashable {
    let entry: SpaceEntry
    let refusal: String?
    /// size relative to the largest entry in the folder, for the bar.
    let share: Double

    var id: String { entry.id }
    var name: String { entry.name }
    var bytes: Int64 { entry.bytes }
    var lastAccessSort: Date { entry.lastAccess ?? .distantPast }
}

@MainActor @Observable
final class SpaceModel {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var folder: URL
    var listing: SpaceListing?
    var state: ScanState = .idle
    var checked: Set<String> = []
    var sortOrder = [KeyPathComparator(\SpaceRow.bytes, order: .reverse)]

    private let engine = SpaceEngine()
    private let policy = SafetyPolicy()
    private var task: Task<Void, Never>?
    private var generation = 0

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
    }

    /// home first, then each folder below it.
    var breadcrumbs: [URL] {
        var trail: [URL] = []
        var current = folder.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        while current.path.hasPrefix(homePath) {
            trail.insert(current, at: 0)
            if current.path == homePath { break }
            current = current.deletingLastPathComponent()
        }
        return trail
    }

    var rows: [SpaceRow] {
        guard let listing else { return [] }
        let largest = max(listing.entries.map(\.bytes).max() ?? 1, 1)
        return listing.entries.map { entry in
            let refusal: String? = if case .refused(let reason) = policy.verdict(for: entry.url) { reason } else { nil }
            return SpaceRow(entry: entry, refusal: refusal, share: Double(entry.bytes) / Double(largest))
        }
        .sorted(using: sortOrder)
    }

    var checkedBytes: Int64 { listing?.entries.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.bytes } ?? 0 }

    func open(_ url: URL) {
        folder = url
        checked = []
        load()
    }

    func load() {
        task?.cancel()
        listing = nil
        state = .scanning(Format.location(folder, home: home.path))
        let target = folder
        generation += 1
        let current = generation
        task = Task {
            do {
                let result = try await engine.list(target)
                guard current == generation else { return }
                listing = result
                state = .done(Date())
            } catch {
                guard current == generation else { return }
                state = Task.isCancelled || error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        task?.cancel()
        generation += 1
        if state.isScanning { state = .idle }
    }

    var checkedItems: [RemovalItem] {
        listing?.entries.filter { checked.contains($0.id) }.map { RemovalItem(url: $0.url, bytes: $0.bytes) } ?? []
    }

    /// drops removed entries, and takes removed files inside an entry off that entry's size.
    func didTrash(_ moved: [TrashOutcome.Moved]) {
        guard let current = listing, !moved.isEmpty else { return }
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        var removedBytes: Int64 = 0
        var entries: [SpaceEntry] = []
        for entry in current.entries {
            if Trasher.covers(paths, entry.id) {
                removedBytes += entry.bytes
                continue
            }
            let inside = moved.filter { $0.original.standardizedFileURL.path.hasPrefix(entry.id + "/") }
            let shrink = inside.reduce(0) { $0 + $1.bytes }
            removedBytes += shrink
            entries.append(shrink == 0 ? entry : SpaceEntry(
                url: entry.url, name: entry.name, bytes: max(entry.bytes - shrink, 0), isDirectory: entry.isDirectory,
                isCleanable: entry.isCleanable, isPartial: entry.isPartial, lastAccess: entry.lastAccess
            ))
        }
        listing = SpaceListing(url: current.url, entries: entries, totalBytes: max(current.totalBytes - removedBytes, 0), isPartial: current.isPartial)
        checked = checked.filter { !Trasher.covers(paths, $0) }
    }
}
