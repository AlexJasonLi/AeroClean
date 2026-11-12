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
    case junk, largeFiles, duplicates, space
    var id: String { rawValue }

    var title: String {
        switch self {
        case .junk: "Junk"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .space: "Space"
        }
    }

    var symbol: String {
        switch self {
        case .junk: "sparkles"
        case .largeFiles: "scalemass"
        case .duplicates: "square.on.square"
        case .space: "folder"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var pane: Pane = .junk
    var disk: DiskStatus?
    /// nil when macOS keeps the trash unreadable without full disk access.
    var trashBytes: Int64?
    var movedThisSession: Int64 = 0
    var missingTools: [Tool] = Tool.missing

    var pendingRemoval: PendingRemoval?
    var isRemoving = false
    var removalProgress: (done: Int, total: Int)?
    var lastOutcome: TrashOutcome?
    var showingFailures = false

    var confirmingEmptyTrash = false
    var isEmptyingTrash = false
    var emptyTrashError: String?

    let junk = JunkModel()
    let largeFiles = LargeFilesModel()
    let duplicates = DuplicatesModel()
    let space = SpaceModel()

    private let trasher = Trasher()

    init() {
        junk.loadLastPreview()
        refreshStorage()
    }

    func recheckTools() {
        missingTools = Tool.missing
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
        let pending = PendingRemoval(items: items, foldersWithGit: nil)
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
        let trasher = trasher
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
            lastOutcome = outcome
            showingFailures = !outcome.failed.isEmpty
            // every pane drops what moved, so no list keeps a file that is already in the trash.
            junk.didTrash(outcome.moved)
            largeFiles.didTrash(outcome.moved)
            duplicates.didTrash(outcome.moved)
            space.didTrash(outcome.moved)
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

    func badge(for pane: Pane) -> Int64? {
        switch pane {
        case .junk: junk.totalBytes
        case .largeFiles: largeFiles.totalBytes
        case .duplicates: duplicates.totalRedundantBytes
        case .space: nil
        }
    }
}
