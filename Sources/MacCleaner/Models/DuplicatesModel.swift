import AppKit
import MacCleanerCore
import Observation

/// a duplicate group, or one copy inside it.
struct DuplicateRow: Identifiable, Hashable {
    let id: String
    let groupID: String
    let name: String
    let location: String
    let bytes: Int64
    let extraBytes: Int64
    let copyCount: Int
    let created: Date?
    let modified: Date?
    let url: URL?
    let children: [DuplicateRow]?

    var isGroup: Bool { children != nil }
    var modifiedSort: Date { modified ?? .distantPast }
}

@MainActor @Observable
final class DuplicatesModel {
    static let thresholds: [Int64] = [1, 10, 50, 100].map { $0 * 1_000_000 }

    var state: ScanState = .idle
    var groups: [DuplicateGroup] = []
    var checked: Set<String> = []
    var minimumBytes: Int64 = 10_000_000
    var sortOrder = [KeyPathComparator(\DuplicateRow.extraBytes, order: .reverse)]

    private let engine = DuplicateEngine()
    private var task: Task<Void, Never>?
    private var generation = 0

    var totalRedundantBytes: Int64? { groups.isEmpty ? nil : groups.reduce(0) { $0 + $1.redundantBytes } }

    var checkedBytes: Int64 {
        groups.reduce(0) { total, group in
            total + group.bytes * Int64(group.copies.filter { checked.contains($0.id) }.count)
        }
    }

    var rows: [DuplicateRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return groups.map { group in
            let copies = group.copies.map { copy in
                DuplicateRow(
                    id: copy.id,
                    groupID: group.id,
                    name: copy.url.lastPathComponent,
                    location: Format.location(copy.url.deletingLastPathComponent(), home: home),
                    bytes: group.bytes,
                    extraBytes: 0,
                    copyCount: 1,
                    created: copy.created,
                    modified: copy.modified,
                    url: copy.url,
                    children: nil
                )
            }
            return DuplicateRow(
                id: "group:" + group.id,
                groupID: group.id,
                name: group.copies.first?.url.lastPathComponent ?? "",
                location: "\(group.copies.count) copies",
                bytes: group.bytes,
                extraBytes: group.redundantBytes,
                copyCount: group.copies.count,
                created: nil,
                modified: group.copies.compactMap(\.modified).max(),
                url: nil,
                children: copies
            )
        }
        .sorted(using: sortOrder)
    }

    func scan() {
        task?.cancel()
        generation += 1
        let current = generation
        state = .scanning(nil)
        let minimum = minimumBytes
        task = Task {
            do {
                let found = try await engine.scan(minimumBytes: minimum)
                guard current == generation else { return }
                groups = found
                checked = []
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
        if state.isScanning { state = groups.isEmpty ? .idle : .done(Date()) }
    }

    /// a copy can be checked unless it is the last unchecked copy of its group.
    func canCheck(_ copyID: String, in groupID: String) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        let unchecked = group.copies.filter { !checked.contains($0.id) }
        return checked.contains(copyID) || unchecked.count > 1
    }

    func setChecked(_ copyID: String, in groupID: String, _ on: Bool) {
        if on {
            guard canCheck(copyID, in: groupID) else { return }
            checked.insert(copyID)
        } else {
            checked.remove(copyID)
        }
    }

    /// checks every copy except the oldest in each group.
    func checkExtraCopies() {
        var next: Set<String> = []
        for group in groups {
            guard let keeper = group.suggestedKeeper else { continue }
            for copy in group.copies where copy.id != keeper.id { next.insert(copy.id) }
        }
        checked = next
    }

    /// never hands over a whole group, even if the checked set was edited around canCheck.
    var checkedItems: [RemovalItem] {
        groups.flatMap { group -> [RemovalItem] in
            let picked = group.copies.filter { checked.contains($0.id) }
            guard picked.count < group.copies.count else { return [] }
            return picked.map { copy in
                RemovalItem(url: copy.url, bytes: group.bytes, survivors: group.copies.filter { $0.id != copy.id }.map(\.url))
            }
        }
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        guard !paths.isEmpty else { return }
        groups = groups.compactMap { group in
            let left = group.copies.filter { !Trasher.covers(paths, $0.id) }
            guard left.count > 1 else { return nil }
            return DuplicateGroup(hash: group.hash, bytes: group.bytes, copies: left)
        }
        checked = checked.filter { !Trasher.covers(paths, $0) }
    }
}
