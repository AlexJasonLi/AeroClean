import AppKit
import MacCleanerCore
import Observation

/// thread-safe flag a background scan polls to stop early.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// the one disk index every pane reads. loads the last one from disk at launch, then rescans.
@MainActor @Observable
final class IndexModel {
    private(set) var index: DiskIndex?
    private(set) var children: [[Int32]] = []
    private(set) var filesByFolder: [Int32: [Int]] = [:]
    private(set) var homeNode: Int32?
    var state: ScanState = .idle
    var progress: FastScanner.Progress?
    /// removed since this index was built: path to bytes. hidden from every list, taken off every total.
    private(set) var removed: [String: Int64] = [:]
    @ObservationIgnored private var removedKeys: Set<String> = []

    let home: String
    private let store: IndexStore
    /// what to scan; nil means the home folder plus the system data folders.
    private let roots: [URL]?
    private var cancel: CancelFlag?
    private var generation = 0

    init(home: String? = nil, roots: [URL]? = nil, store: IndexStore = IndexStore()) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        self.roots = roots
        self.store = store
    }

    func start() {
        Task {
            let store = store
            if let cached = await Task.detached(priority: .userInitiated, operation: { store.load() }).value, index == nil {
                apply(cached)
            }
            scan()
        }
    }

    func scan() {
        cancel?.set()
        let flag = CancelFlag()
        cancel = flag
        generation += 1
        let current = generation
        state = .scanning(nil)
        progress = nil
        let roots = self.roots ?? [URL(fileURLWithPath: home)] + SystemProbe.systemRoots
        let store = store
        Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                FastScanner.scan(roots: roots, progress: { report in
                    Task { @MainActor in if current == self.generation { self.progress = report } }
                }, isCancelled: { flag.isSet })
            }.value
            guard current == generation, !flag.isSet else { return }
            apply(fresh)
            state = .done(fresh.scannedAt)
            Task.detached(priority: .utility) { store.save(fresh) }
        }
    }

    /// stops a running scan and keeps the last finished index on screen.
    func stop() {
        guard state.isScanning else { return }
        cancel?.set()
        cancel = nil
        generation += 1
        progress = nil
        state = index.map { .done($0.scannedAt) } ?? .idle
    }

    private func apply(_ fresh: DiskIndex) {
        let kids = fresh.childFolders
        var byFolder: [Int32: [Int]] = [:]
        for (position, file) in fresh.files.enumerated() { byFolder[file.folder, default: []].append(position) }
        index = fresh
        children = kids
        filesByFolder = byFolder
        homeNode = fresh.rootPaths.firstIndex(of: home).map { fresh.roots[$0] }
        removed = [:]
        removedKeys = []
        if case .scanning = state {} else { state = .done(fresh.scannedAt) }
    }

    // MARK: lookups

    func path(_ node: Int32) -> String { index?.path(of: node) ?? "" }

    func node(at path: String) -> Int32? {
        guard let index else { return nil }
        for (position, rootPath) in index.rootPaths.enumerated() where path == rootPath || path.hasPrefix(rootPath + "/") {
            var node = index.roots[position]
            for part in path.dropFirst(rootPath.count).split(separator: "/") {
                guard let next = children[Int(node)].first(where: { index.names[Int($0)] == part }) else { return nil }
                node = next
            }
            return node
        }
        return nil
    }

    func isRemoved(_ path: String) -> Bool { !removedKeys.isEmpty && Trasher.covers(removedKeys, path) }

    var removedPaths: [String] { Array(removed.keys) }

    /// a folder's size after removals since the scan.
    func total(_ node: Int32) -> Int64 {
        guard let index else { return 0 }
        let base = index.totals[Int(node)]
        guard !removed.isEmpty else { return base }
        let path = index.path(of: node)
        if isRemoved(path) { return 0 }
        let gone = removed.filter { $0.key.hasPrefix(path + "/") }.reduce(0) { $0 + $1.value }
        return max(base - gone, 0)
    }

    func total(at path: String) -> Int64? { node(at: path).map(total) }

    /// child folders by size, biggest first.
    func biggestChildren(of node: Int32, limit: Int = .max, atLeast minimum: Int64 = 0) -> [Int32] {
        guard Int(node) < children.count else { return [] }
        return children[Int(node)]
            .map { ($0, total($0)) }
            .filter { $0.1 >= minimum && $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        for item in moved { removed[item.original.standardizedFileURL.path] = item.bytes }
        removedKeys = Set(removed.keys)
    }
}
