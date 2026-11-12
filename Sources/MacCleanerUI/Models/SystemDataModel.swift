import AppKit
import MacCleanerCore
import Observation

/// one place that macOS counts as system data.
struct SystemRow: Identifiable, Hashable {
    let id: String
    let title: String
    /// one short line: what it is, or how to free it.
    let note: String
    let bytes: Int64
    /// set when it is a real folder or file you can reveal.
    let path: String?
    /// set when MacCleaner can move it to the trash.
    let removable: Bool
    /// the app whose icon to show, if any.
    let owner: String?
}

struct SystemSection: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [SystemRow]
    var total: Int64 { rows.reduce(0) { $0 + $1.bytes } }
}

/// explains "system data": macOS volumes, app data, caches, temporary files, developer
/// tools and hidden folders, each measured by the index.
@MainActor @Observable
final class SystemDataModel {
    var volumes = SystemVolumes()
    var purgeable: Int64?
    var checked: Set<String> = []
    private let policy = SafetyPolicy()

    func refreshVolumes() {
        Task {
            volumes = await SystemProbe.volumes()
            purgeable = SystemProbe.purgeable()
        }
    }

    func sections(_ model: IndexModel) -> [SystemSection] {
        guard model.index != nil else { return [] }
        let home = model.home
        var sections: [SystemSection] = []

        // apps' own data: the biggest folders apps keep, opened one level when one part dominates.
        var appRows: [SystemRow] = []
        for area in ["Library/Application Support", "Library/Containers", "Library/Group Containers"] {
            guard let node = model.node(at: home + "/" + area) else { continue }
            for child in model.biggestChildren(of: node, limit: 10, atLeast: 300_000_000) {
                appRows.append(appRow(child, model))
            }
        }
        appRows.sort { $0.bytes > $1.bytes }
        sections.append(SystemSection(id: "apps", title: "Apps keep", rows: Array(appRows.prefix(10))))

        // caches
        var cacheRows: [SystemRow] = []
        if let caches = model.node(at: home + "/Library/Caches") {
            for child in model.biggestChildren(of: caches, limit: 6, atLeast: 150_000_000) {
                let name = model.index!.names[Int(child)]
                cacheRows.append(row(child, model, title: Icons.appName(name) ?? name, note: "Cache, rebuilt when needed", owner: name))
            }
        }
        if let logs = model.node(at: home + "/Library/Logs"), model.total(logs) > 50_000_000 {
            cacheRows.append(row(logs, model, title: "Your logs", note: "Records apps keep, safe to clear", owner: nil))
        }
        if let caches = model.node(at: "/Library/Caches"), model.total(caches) > 100_000_000 {
            cacheRows.append(row(caches, model, title: "Shared caches", note: "Needs an administrator", owner: nil))
        }
        sections.append(SystemSection(id: "caches", title: "Caches", rows: cacheRows))

        // temporary files in /var/folders
        var tempRows: [SystemRow] = []
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath()
        let varFolder = tempRoot.deletingLastPathComponent().path
        if let clones = model.node(at: varFolder + "/X") {
            for child in model.biggestChildren(of: clones, limit: 4, atLeast: 100_000_000) {
                let name = model.index!.names[Int(child)]
                let app = name.replacingOccurrences(of: ".code_sign_clone", with: "")
                let appName = Icons.appName(app) ?? app
                tempRows.append(row(child, model, title: "\(appName) update copies", note: "Left behind by updates. Quit \(appName) first", owner: app))
            }
        }
        if let temp = model.node(at: tempRoot.path), model.total(temp) > 50_000_000 {
            let big = model.biggestChildren(of: temp, limit: 200, atLeast: 20_000_000)
            for child in big.prefix(6) {
                tempRows.append(row(child, model, title: model.index!.names[Int(child)], note: "Temporary files an app left", owner: nil))
            }
            let rest = model.total(temp) - big.prefix(6).reduce(0) { $0 + model.total($1) }
            if rest > 50_000_000 {
                tempRows.append(SystemRow(id: "temp-rest", title: "Other temporary files", note: "Cleared when you restart", bytes: rest,
                                          path: tempRoot.path, removable: false, owner: nil))
            }
        }
        if let cache = model.node(at: varFolder + "/C"), model.total(cache) > 100_000_000 {
            tempRows.append(row(cache, model, title: "System caches for you", note: "macOS manages these", owner: nil, removable: false))
        }
        sections.append(SystemSection(id: "temp", title: "Temporary", rows: tempRows))

        // developer tools
        var devRows: [SystemRow] = []
        if let devices = model.node(at: home + "/Library/Developer/CoreSimulator"), model.total(devices) > 100_000_000 {
            devRows.append(row(devices, model, title: "Simulator devices", note: "Delete old ones in Xcode › Devices", owner: "com.apple.dt.Xcode", removable: false))
        }
        if let xcode = model.node(at: home + "/Library/Developer/Xcode") {
            for child in model.biggestChildren(of: xcode, limit: 4, atLeast: 100_000_000) {
                let name = model.index!.names[Int(child)]
                let note = name == "DerivedData" ? "Build products, rebuilt when needed" : "Xcode data"
                devRows.append(row(child, model, title: "Xcode \(name)", note: note, owner: "com.apple.dt.Xcode"))
            }
        }
        var runtimes: Int64 = 0
        for path in ["/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime", "/Library/Developer/CoreSimulator"] {
            runtimes += model.total(at: path) ?? 0
        }
        if runtimes > 100_000_000 {
            devRows.append(SystemRow(id: "runtimes", title: "Simulator runtimes", note: "Remove in Xcode › Settings › Components",
                                     bytes: runtimes, path: "/Library/Developer/CoreSimulator", removable: false, owner: "com.apple.dt.Xcode"))
        }
        sections.append(SystemSection(id: "dev", title: "Developer", rows: devRows))

        // hidden folders in the home folder
        var hiddenRows: [SystemRow] = []
        if let homeNode = model.homeNode, let index = model.index {
            for child in model.biggestChildren(of: homeNode, atLeast: 150_000_000) where index.names[Int(child)].hasPrefix(".") {
                let name = index.names[Int(child)]
                guard name != ".Trash" else { continue }
                hiddenRows.append(row(child, model, title: name, note: "Hidden folder a tool keeps", owner: nil))
                if hiddenRows.count == 8 { break }
            }
        }
        sections.append(SystemSection(id: "hidden", title: "Hidden", rows: hiddenRows))

        // macOS itself
        var osRows: [SystemRow] = []
        if volumes.swap > 0 {
            osRows.append(SystemRow(id: "swap", title: "Swap", note: "Memory overflow. Shrinks after a restart", bytes: volumes.swap,
                                    path: nil, removable: false, owner: nil))
        }
        if volumes.preboot > 0 {
            osRows.append(SystemRow(id: "preboot", title: "Startup files", note: "macOS needs these", bytes: volumes.preboot,
                                    path: nil, removable: false, owner: nil))
        }
        if volumes.recovery > 0 {
            osRows.append(SystemRow(id: "recovery", title: "Recovery", note: "macOS needs this", bytes: volumes.recovery,
                                    path: nil, removable: false, owner: nil))
        }
        if let updates = model.node(at: "/Library/Updates"), model.total(updates) > 50_000_000 {
            osRows.append(row(updates, model, title: "Downloaded updates", note: "Install or let Software Update clear them",
                              owner: "com.apple.systempreferences", removable: false))
        }
        if let assets = model.node(at: "/System/Library/AssetsV2") {
            let other = model.total(assets) - (model.total(at: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime") ?? 0)
            if other > 100_000_000 {
                osRows.append(SystemRow(id: "assets", title: "macOS assets", note: "Voices, Siri and language models", bytes: other,
                                        path: "/System/Library/AssetsV2", removable: false, owner: nil))
            }
        }
        if let logs = model.node(at: "/private/var/log"), model.total(logs) > 50_000_000 {
            osRows.append(row(logs, model, title: "System logs", note: "macOS rotates these", owner: nil, removable: false))
        }
        if let purgeable, purgeable > 200_000_000 {
            osRows.append(SystemRow(id: "purgeable", title: "Purgeable", note: "macOS frees this itself when space runs low", bytes: purgeable,
                                    path: nil, removable: false, owner: nil))
        }
        if volumes.localSnapshots > 0 {
            osRows.append(SystemRow(id: "snapshots", title: "\(volumes.localSnapshots) Time Machine snapshots", note: "Removed as space runs low",
                                    bytes: 0, path: nil, removable: false, owner: nil))
        }
        sections.append(SystemSection(id: "macos", title: "macOS", rows: osRows))

        return sections.filter { !$0.rows.isEmpty }
    }

    private func appRow(_ node: Int32, _ model: IndexModel) -> SystemRow {
        let index = model.index!
        let name = index.names[Int(node)]
        let appName = Icons.appName(name) ?? name
        let total = model.total(node)
        // when one part of an app's folder holds most of it, name that part.
        if let biggest = model.biggestChildren(of: node, limit: 1).first {
            let part = model.total(biggest)
            if part > 1_000_000_000, Double(part) / Double(max(total, 1)) > 0.6 {
                let partName = index.names[Int(biggest)]
                let note = Self.knownParts[partName] ?? "Most of \(appName)'s data"
                return row(biggest, model, title: "\(appName) · \(partName)", note: note, owner: name)
            }
        }
        return row(node, model, title: appName, note: "Data \(appName) keeps", owner: name)
    }

    /// short explanations for big folders that show up often.
    static let knownParts: [String: String] = [
        "vm_bundles": "Virtual machine image for its sandbox",
        "snapshots": "Saved snapshots the app keeps",
        "Chrome": "Chrome profiles, history and caches",
        "Service Worker": "Website data saved by the browser",
        "Cache": "Cache, rebuilt when needed",
        "CachedData": "Cache, rebuilt when needed",
        "workspaceStorage": "Per-project state the editor keeps",
        "Media Cache Files": "Adobe media cache, rebuilt when needed",
    ]

    private func row(_ node: Int32, _ model: IndexModel, title: String, note: String, owner: String?, removable: Bool? = nil) -> SystemRow {
        let path = model.path(node)
        let allowed = policy.verdict(for: URL(fileURLWithPath: path)).isAllowed
        return SystemRow(id: path, title: title, note: note, bytes: model.total(node), path: path,
                         removable: (removable ?? true) && allowed, owner: owner)
    }

    func checkedItems(_ sections: [SystemSection]) -> [RemovalItem] {
        sections.flatMap(\.rows).filter { $0.removable && checked.contains($0.id) }.compactMap { row in
            row.path.map { RemovalItem(url: URL(fileURLWithPath: $0), bytes: row.bytes) }
        }
    }

    func didTrash(_ moved: [TrashOutcome.Moved]) {
        let paths = Set(moved.map { $0.original.standardizedFileURL.path })
        checked = checked.filter { !Trasher.covers(paths, $0) }
    }
}
