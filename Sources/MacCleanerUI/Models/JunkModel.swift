import AppKit
import MacCleanerCore
import Observation

/// a row of the junk table: an app or tool with its paths, or one path.
struct JunkRow: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let section: String
    let bytes: Int64
    let itemCount: Int
    let url: URL?
    let children: [JunkRow]?
    let refusal: String?

    var isGroup: Bool { children != nil }
    var leafIDs: [String] { children?.map(\.id) ?? [id] }
}

@MainActor @Observable
final class JunkModel {
    var state: ScanState = .idle
    var items: [JunkItem] = []
    var rows: [JunkRow] = []
    var checked: Set<String> = []
    var scannedAt: Date?
    var sortOrder = [KeyPathComparator(\JunkRow.bytes, order: .reverse)] {
        didSet { rebuildRows() }
    }

    private let engine = JunkEngine()
    private let policy = SafetyPolicy()
    private var task: Task<Void, Never>?

    var step: String? { if case .scanning(let step) = state { step } else { nil } }

    var totalBytes: Int64? { items.isEmpty ? nil : items.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var checkedBytes: Int64 { items.lazy.filter { self.checked.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) } }

    /// shows mole's last preview straight away, minus anything already gone.
    func loadLastPreview() {
        guard let preview = engine.lastPreview() else { return }
        let manager = FileManager.default
        apply(preview.items.filter { manager.fileExists(atPath: $0.url.path) }, date: preview.date)
    }

    func scan() {
        guard !state.isScanning else { return }
        state = .scanning(nil)
        task = Task {
            do {
                let result = try await engine.scan { section in
                    Task { @MainActor in
                        if self.state.isScanning { self.state = .scanning(section) }
                    }
                }
                apply(result.items, date: result.date)
            } catch is CancellationError {
                state = scannedAt.map { .done($0) } ?? .idle
            } catch {
                state = Task.isCancelled ? (scannedAt.map { .done($0) } ?? .idle) : .failed(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    private func apply(_ items: [JunkItem], date: Date) {
        self.items = items
        scannedAt = date
        state = .done(date)
        checked = checked.intersection(items.map(\.id))
        rebuildRows()
    }

    func rebuildRows() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let grouped = Dictionary(grouping: items) { "\($0.section)\u{1F}\($0.owner)" }
        var groups: [JunkRow] = grouped.map { key, members in
            let first = members[0]
            var children = members.map { item in
                JunkRow(
                    id: item.id,
                    name: item.url.lastPathComponent,
                    detail: Format.location(item.url.deletingLastPathComponent(), home: home),
                    section: item.section,
                    bytes: item.bytes ?? 0,
                    itemCount: item.itemCount,
                    url: item.url,
                    children: nil,
                    refusal: refusal(for: item.url)
                )
            }
            children.sort(using: sortOrder)
            return JunkRow(
                id: "group:" + key,
                name: first.owner,
                detail: members.count == 1 ? "1 location" : "\(members.count) locations",
                section: first.section,
                bytes: members.reduce(0) { $0 + ($1.bytes ?? 0) },
                itemCount: members.reduce(0) { $0 + $1.itemCount },
                url: nil,
                children: children,
                refusal: nil
            )
        }
        groups.sort(using: sortOrder)
        rows = groups
    }

    private func refusal(for url: URL) -> String? {
        if case .refused(let reason) = policy.verdict(for: url) { return reason }
        return nil
    }

    func checkAll(_ on: Bool) {
        let removable = rows.flatMap { $0.children ?? [] }.filter { $0.refusal == nil }.map(\.id)
        checked = on ? Set(removable) : []
    }

    var checkedItems: [RemovalItem] {
        items.filter { checked.contains($0.id) }.map { RemovalItem(url: $0.url, bytes: $0.bytes ?? 0) }
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        guard !paths.isEmpty else { return }
        items.removeAll { Trasher.covers(paths, $0.id) }
        checked = checked.filter { !Trasher.covers(paths, $0) }
        rebuildRows()
    }
}
