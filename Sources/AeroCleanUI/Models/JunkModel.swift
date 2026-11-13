import AppKit
import AeroCleanCore
import Observation

/// a row of the junk list: a kind of junk, or one app's share of it.
struct JunkRow: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let bytes: Int64
    /// item paths this row stands for.
    let paths: [String]
    let children: [JunkRow]?
    /// the app whose icon to show.
    let owner: String?
    /// set on rows AeroClean left out of junk: why.
    let doubt: String?
}

/// mole finds candidates; AeroClean keeps only those its junk rules vouch for.
@MainActor @Observable
final class JunkModel {
    var state: ScanState = .idle
    /// items that passed the rules, by path.
    var items: [JunkItem] = []
    private(set) var kinds: [String: JunkKind] = [:]
    var rows: [JunkRow] = []
    /// what mole listed that AeroClean will not call junk, grouped by reason.
    var leftOut: [JunkRow] = []
    var checked: Set<String> = []
    var scannedAt: Date?

    private let engine = JunkEngine()
    private var task: Task<Void, Never>?

    var step: String? { if case .scanning(let step) = state { step } else { nil } }
    var totalBytes: Int64? { items.isEmpty ? nil : items.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var leftOutBytes: Int64 { leftOut.reduce(0) { $0 + $1.bytes } }
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
            } catch {
                state = Task.isCancelled || error is CancellationError ? (scannedAt.map { .done($0) } ?? .idle) : .failed(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    private func apply(_ candidates: [JunkItem], date: Date) {
        let rules = JunkRules()
        var kept: [JunkItem] = []
        var kinds: [String: JunkKind] = [:]
        var doubts: [String: [JunkItem]] = [:]
        for item in candidates {
            switch rules.classify(item.url.standardizedFileURL.path) {
            case .junk(let kind):
                kept.append(item)
                kinds[item.id] = kind
            case .doubt(let reason):
                doubts[reason, default: []].append(item)
            }
        }
        items = kept
        self.kinds = kinds
        scannedAt = date
        state = .done(date)
        checked = checked.intersection(kept.map(\.id))
        rows = Self.group(kept, kinds: kinds)
        leftOut = doubts.map { reason, members in
            JunkRow(id: "doubt:" + reason, name: reason, detail: Format.items(members.count),
                    bytes: members.reduce(0) { $0 + ($1.bytes ?? 0) }, paths: members.map(\.id),
                    children: nil, owner: nil, doubt: reason)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// kinds of junk, each holding one row per app or tool.
    static func group(_ items: [JunkItem], kinds: [String: JunkKind]) -> [JunkRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let byKind = Dictionary(grouping: items) { kinds[$0.id] ?? .cache }
        return byKind.map { kind, members in
            let byOwner = Dictionary(grouping: members, by: \.owner)
            let children = byOwner.map { owner, group -> JunkRow in
                let bytes = group.reduce(0) { $0 + ($1.bytes ?? 0) }
                let detail = group.count == 1
                    ? Format.location(group[0].url.deletingLastPathComponent(), home: home)
                    : "\(Format.count(group.count)) places"
                return JunkRow(id: "owner:\(kind.rawValue):\(owner)", name: Icons.appName(owner) ?? owner, detail: detail,
                               bytes: bytes, paths: group.map(\.id), children: nil, owner: owner, doubt: nil)
            }
            .sorted { $0.bytes > $1.bytes }
            return JunkRow(id: "kind:" + kind.rawValue, name: kind.title, detail: kind.reason,
                           bytes: members.reduce(0) { $0 + ($1.bytes ?? 0) }, paths: members.map(\.id),
                           children: children, owner: nil, doubt: nil)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    func checkAll(_ on: Bool) {
        checked = on ? Set(items.map(\.id)) : []
    }

    func toggle(_ paths: [String]) {
        if paths.allSatisfy(checked.contains) { checked.subtract(paths) } else { checked.formUnion(paths) }
    }

    func state(of paths: [String]) -> Bool? {
        let count = paths.filter(checked.contains).count
        return count == 0 ? false : (count == paths.count ? true : nil)
    }

    var checkedItems: [RemovalItem] {
        items.filter { checked.contains($0.id) }.map { RemovalItem(url: $0.url, bytes: $0.bytes ?? 0) }
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        guard !paths.isEmpty else { return }
        items.removeAll { Trasher.covers(paths, $0.id) }
        checked = checked.filter { !Trasher.covers(paths, $0) }
        rows = Self.group(items, kinds: kinds)
    }
}
