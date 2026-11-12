import AppKit
import MacCleanerCore
import Observation

/// something the user checked for removal, as shown in the confirmation sheet.
struct RemovalItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let bytes: Int64
    /// for a duplicate, its other copies; one must still be on disk when it is removed.
    var survivors: [URL] = []

    var request: TrashRequest { TrashRequest(url: url, bytes: bytes, survivors: survivors) }
}

struct PendingRemoval: Identifiable {
    let id = UUID()
    let items: [RemovalItem]
    /// the pane it came from; junk gets the strictest checks.
    var source: Pane = .junk
    /// how many checked folders hold git repositories; nil while still looking.
    var foldersWithGit: Int?

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

enum ScanState: Equatable {
    case idle
    case scanning(String?)
    case done(Date)
    case failed(String)

    var isScanning: Bool { if case .scanning = self { true } else { false } }
}

enum Pane: String, CaseIterable, Identifiable {
    case junk, large, copies, space, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: "Junk"
        case .large: "Large"
        case .copies: "Copies"
        case .space: "Space"
        case .system: "System"
        }
    }

    var glyph: Glyph {
        switch self {
        case .junk: .sparkle
        case .large: .weight
        case .copies: .copies
        case .space: .folder
        case .system: .computer
        }
    }

    var scene: SceneKind {
        switch self {
        case .junk: .dandelionHill
        case .large: .summerRidge
        case .copies: .stillPond
        case .space: .valleyFields
        case .system: .duskMeadow
        }
    }
}

@MainActor @Observable
public final class AppModel {
    var pane: Pane = .junk
    var disk: DiskStatus?
    /// nil when macOS keeps the trash unreadable without full disk access.
    var trashBytes: Int64?
    var movedThisSession: Int64 = 0
    var missingTools: [Tool] = Tool.missing.filter { $0 != .fd }

    var pendingRemoval: PendingRemoval?
    var isRemoving = false
    var removalProgress: (done: Int, total: Int)?
    var lastOutcome: TrashOutcome?
    var showingFailures = false
    /// bumps on every successful removal, so the scene can scatter petals.
    var celebration = 0

    var confirmingEmptyTrash = false
    var isEmptyingTrash = false
    var emptyTrashError: String?
    var preview: URL?

    let index = IndexModel()
    let junk = JunkModel()
    let large = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let space = SpaceModel()
    let system = SystemDataModel()


    public init() {
        junk.loadLastPreview()
        refreshStorage()
        index.start()
        system.refreshVolumes()
    }

    struct RunningApp: Sendable {
        let bundle: String
        let name: String
    }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { RunningApp(bundle: $0.lowercased(), name: app.localizedName ?? $0) } }
    }

    /// refuses caches and data of apps that are running right now.
    nonisolated static func inUseReason(_ url: URL, running: [RunningApp]) -> String? {
        let path = url.standardizedFileURL.path
        for owner in AppOwners.owners(of: path) where running.contains(where: { app in owner.bundles.contains { app.bundle.hasPrefix($0.lowercased()) } }) {
            return "Quit \(owner.label) first"
        }
        let parts = url.standardizedFileURL.pathComponents
        let inAppData = parts.contains("Application Support") || parts.contains("Caches") || parts.contains("Containers")
        for app in running {
            if parts.contains(where: { $0.lowercased() == app.bundle || $0.lowercased().hasPrefix(app.bundle + ".") }) {
                return "Quit \(app.name) first"
            }
            if inAppData, app.name != "Finder", parts.contains(app.name) {
                return "Quit \(app.name) first"
            }
        }
        return nil
    }

    func recheckTools() {
        missingTools = Tool.missing.filter { $0 != .fd }
    }

    func refreshStorage() {
        disk = DiskStatus.current()
        Task {
            let size = await Task.detached(priority: .utility) { TrashService.size() }.value
            trashBytes = size
        }
    }

    func requestRemoval(_ items: [RemovalItem]) {
        guard !items.isEmpty, !isRemoving else { return }
        let pending = PendingRemoval(items: items, source: pane, foldersWithGit: nil)
        pendingRemoval = pending
        // a whole project folder can go, but say so when it carries git history.
        let folders = items.count <= 200 ? items.map(\.url) : []
        Task {
            let count = await Task.detached(priority: .userInitiated) {
                folders.filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        && FolderInspector.inspect(url, limit: 5_000).gitRepositories > 0
                }.count
            }.value
            if pendingRemoval?.id == pending.id { pendingRemoval?.foldersWithGit = count }
        }
    }

    func confirmRemoval() {
        guard let pending = pendingRemoval, !isRemoving else { return }
        isRemoving = true
        removalProgress = (0, pending.items.count)
        let running = Self.runningApps()
        let strict = pending.source == .junk
        let rules = strict ? JunkRules() : nil
        let trasher = Trasher(inUse: { url in
            if let reason = AppModel.inUseReason(url, running: running) { return reason }
            guard let rules else { return nil }
            // junk is checked again at the moment it moves: still junk, and not being written to.
            if case .doubt(let reason) = rules.classify(url.standardizedFileURL.path) { return "Not junk: \(reason.lowercased())" }
            if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) < 300
            {
                return "In use right now, try again later"
            }
            return nil
        })
        let requests = pending.items.map(\.request)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                trasher.trash(requests) { done, total in
                    Task { @MainActor in
                        if self.isRemoving { self.removalProgress = (done, total) }
                    }
                }
            }.value
            isRemoving = false
            removalProgress = nil
            pendingRemoval = nil
            movedThisSession += outcome.bytesMoved
            lastOutcome = outcome.moved.isEmpty ? nil : outcome
            showingFailures = !outcome.failed.isEmpty
            if !outcome.moved.isEmpty { celebration += 1 }
            // every view drops what moved, so no list keeps a file that is already in the trash.
            index.didTrash(outcome.moved)
            junk.didTrash(outcome.moved)
            large.didTrash(outcome.moved)
            duplicates.didTrash(outcome.moved)
            space.didTrash(outcome.moved)
            system.didTrash(outcome.moved)
            refreshStorage()
        }
    }

    func emptyTrash() async {
        isEmptyingTrash = true
        defer { isEmptyingTrash = false }
        do {
            try await TrashService.empty()
            movedThisSession = 0
            lastOutcome = nil
        } catch {
            emptyTrashError = error.localizedDescription
        }
        refreshStorage()
    }

    /// the scan button in the hero: what it does depends on the pane.
    func scan() {
        switch pane {
        case .junk: junk.state.isScanning ? junk.stop() : junk.scan()
        case .copies: duplicates.state.isScanning ? duplicates.stop() : duplicates.scan(index: index)
        case .large, .space:
            index.scan()
        case .system:
            index.scan()
            system.refreshVolumes()
        }
    }

    var isScanning: Bool {
        switch pane {
        case .junk: junk.state.isScanning
        case .copies: duplicates.state.isScanning
        case .large, .space, .system: index.state.isScanning
        }
    }
}
