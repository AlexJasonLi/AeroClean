import Foundation

/// what a folder holds that matters before it goes to the trash as a whole.
public struct FolderReport: Sendable, Equatable {
    /// media libraries inside, by name. a folder holding one is never removed.
    public var mediaLibraries: [String] = []
    /// git repositories inside: their history goes to the trash with the folder.
    public var gitRepositories = 0
    /// the folder had more entries than the limit, so not all of it was looked at.
    public var truncated = false
}

public enum FolderInspector {
    /// looks through a folder breadth first, so shallow libraries are found before the limit.
    /// bundles and libraries are not opened.
    public static func inspect(_ folder: URL, limit: Int = 20_000) -> FolderReport {
        var report = FolderReport()
        var queue = [folder]
        var head = 0
        var seen = 0
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        while head < queue.count {
            let current = queue[head]
            head += 1
            guard let children = try? manager.contentsOfDirectory(at: current, includingPropertiesForKeys: keys, options: [])
            else { continue }
            for child in children {
                seen += 1
                if seen > limit {
                    report.truncated = true
                    return report
                }
                let name = child.lastPathComponent
                let ext = child.pathExtension.lowercased()
                if SafetyPolicy.mediaLibraryExtensions.contains(ext) {
                    report.mediaLibraries.append(name)
                    continue
                }
                if name == ".git" {
                    report.gitRepositories += 1
                    continue
                }
                let values = try? child.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if SafetyPolicy.codeBundleExtensions.contains(ext), SafetyPolicy.isCodeBundle(child.path) { continue }
                queue.append(child)
            }
        }
        return report
    }
}
