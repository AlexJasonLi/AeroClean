import Foundation

/// space macOS keeps outside any folder you can browse: its own volumes and snapshots.
public struct SystemVolumes: Sendable, Equatable {
    /// swap files.
    public var swap: Int64 = 0
    /// files the Mac needs to start up, including staged system updates.
    public var preboot: Int64 = 0
    public var recovery: Int64 = 0
    /// a macOS update being prepared.
    public var update: Int64 = 0
    /// the sealed macOS system volume.
    public var system: Int64 = 0
    public var localSnapshots = 0

    public init() {}
}

public enum SystemProbe {
    /// reads `diskutil apfs list -plist` for the container that holds the home folder.
    public static func volumes() async -> SystemVolumes {
        var result = SystemVolumes()
        let diskutil = URL(fileURLWithPath: "/usr/sbin/diskutil")
        if let output = try? await ProcessRunner.run(diskutil, ["apfs", "list", "-plist"]), output.status == 0 {
            result = parse(output.stdout) ?? result
        }
        let tmutil = URL(fileURLWithPath: "/usr/bin/tmutil")
        if let output = try? await ProcessRunner.run(tmutil, ["listlocalsnapshots", "/"]), output.status == 0 {
            result.localSnapshots = String(decoding: output.stdout, as: UTF8.self)
                .split(separator: "\n").filter { $0.hasPrefix("com.apple.TimeMachine") }.count
        }
        return result
    }

    static func parse(_ data: Data) -> SystemVolumes? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]]
        else { return nil }
        // the container with a Data volume is the internal disk; the others are simulators and firmware.
        guard let main = containers.first(where: { container in
            (container["Volumes"] as? [[String: Any]])?.contains { ($0["Roles"] as? [String])?.contains("Data") == true } == true
        }), let volumes = main["Volumes"] as? [[String: Any]]
        else { return nil }
        var result = SystemVolumes()
        for volume in volumes {
            let bytes = (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
            for role in volume["Roles"] as? [String] ?? [] {
                switch role {
                case "VM": result.swap += bytes
                case "Preboot": result.preboot += bytes
                case "Recovery": result.recovery += bytes
                case "Update": result.update += bytes
                case "System": result.system += bytes
                default: break
                }
            }
        }
        return result
    }

    /// what the Finder counts as available beyond truly free space: space macOS can
    /// reclaim by itself, such as snapshots and files already in iCloud.
    public static func purgeable(for url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let free = values.volumeAvailableCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return max(important - Int64(free), 0)
    }

    /// folders scanned alongside the home folder, for the system data view.
    public static var systemRoots: [URL] {
        var roots = ["/Library", "/private/var/log", "/System/Library/AssetsV2"].map { URL(fileURLWithPath: $0) }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
        if temp.path.contains("/var/folders/") { roots.append(temp.deletingLastPathComponent()) }
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// keeps the last index on disk so the app opens on real numbers, then rescans quietly.
public struct IndexStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/local.maccleaner/index.plist"))
    {
        self.fileURL = fileURL
    }

    public func load() -> DiskIndex? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(DiskIndex.self, from: data)
    }

    public func save(_ index: DiskIndex) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
