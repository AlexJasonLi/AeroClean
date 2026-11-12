import Foundation
import UniformTypeIdentifiers

public struct LargeFile: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    /// space the file takes on disk (a sparse disk image can be smaller than its length).
    public let bytes: Int64
    public let modified: Date?
    /// from spotlight; nil when the file was never opened through the finder or an app.
    public let lastOpened: Date?
    public let kind: String
    /// inside a hidden folder such as ~/.cache: tool data, not a document.
    public let isHidden: Bool
}

/// finds files above a size with fd, then measures each hit.
public struct LargeFileEngine: Sendable {
    public let home: URL
    public let policy: SafetyPolicy

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        policy = SafetyPolicy(home: home)
    }

    /// `found` gets each file as fd reports it, so the list fills in while the scan runs.
    public func scan(
        minimumBytes: Int64,
        includeLibrary: Bool,
        found: @escaping @Sendable (LargeFile) -> Void
    ) async throws -> Int {
        guard let fd = Tool.fd.location else { throw MissingTool(tool: .fd) }
        var arguments = [
            ".", home.path,
            "--type", "f",
            "--size", "+\(minimumBytes)b",
            "--hidden", "--no-ignore",
            "--absolute-path", "--print0",
            // patterns starting with / are anchored at the home folder.
            "--exclude", "/.Trash",
            "--exclude", ".git",
            "--exclude", "/Library/Mobile Documents",
            "--exclude", "/Library/CloudStorage",
        ]
        if !includeLibrary { arguments += ["--exclude", "/Library"] }
        for ext in SafetyPolicy.mediaLibraryExtensions { arguments += ["--exclude", "*.\(ext)"] }

        let counter = Counter()
        let result = try await ProcessRunner.run(fd, arguments, delimiter: 0) { path in
            guard !path.isEmpty, let file = Self.measure(path, policy: policy, minimumBytes: minimumBytes) else { return }
            counter.increment()
            found(file)
        }
        try Task.checkCancellation()
        // fd exits 1 when some folders could not be read; the hits it printed are still good.
        guard result.status == 0 || result.status == 1 else {
            throw ProcessFailure(tool: "fd", status: result.status, stderr: result.stderr)
        }
        return counter.value
    }

    static func measure(_ path: String, policy: SafetyPolicy, minimumBytes: Int64) -> LargeFile? {
        let url = URL(fileURLWithPath: path)
        guard policy.verdict(for: url).isAllowed else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .contentTypeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        guard allocated >= minimumBytes else { return nil }
        let relative = path.dropFirst(policy.homePath.count + 1)
        let hidden = relative.split(separator: "/").dropLast().contains { $0.hasPrefix(".") }
        return LargeFile(
            url: url,
            bytes: allocated,
            modified: values.contentModificationDate,
            lastOpened: lastUsedDate(url),
            kind: kindName(values.contentType),
            isHidden: hidden
        )
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    static func kindName(_ type: UTType?) -> String {
        guard let type else { return "File" }
        let families: [(UTType, String)] = [
            (.movie, "Video"), (.audio, "Audio"), (.image, "Image"), (.diskImage, "Disk image"),
            (.archive, "Archive"), (.pdf, "PDF"), (.executable, "Program"), (.database, "Database"),
            (.log, "Log"), (.sourceCode, "Code"), (.text, "Text"),
        ]
        for (family, name) in families where type.conforms(to: family) { return name }
        return type.localizedDescription ?? "File"
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
