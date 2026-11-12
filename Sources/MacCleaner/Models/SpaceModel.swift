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
        task = Task {
            do {
                let result = try await engine.list(target)
                guard target == folder else { return }
                listing = result
                state = .done(Date())
            } catch {
                guard target == folder else { return }
                state = Task.isCancelled || error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    var checkedItems: [RemovalItem] {
        listing?.entries.filter { checked.contains($0.id) }.map { RemovalItem(url: $0.url, bytes: $0.bytes) } ?? []
    }

    func didTrash(_ paths: Set<String>) {
        guard let current = listing else { return }
        let left = current.entries.filter { !paths.contains($0.id) }
        let removed = current.entries.filter { paths.contains($0.id) }.reduce(0) { $0 + $1.bytes }
        listing = SpaceListing(url: current.url, entries: left, totalBytes: current.totalBytes - removed, isPartial: current.isPartial)
        checked.subtract(paths)
    }
}
