import AppKit
import MacCleanerCore
import Observation

struct LargeFileRow: Identifiable, Hashable {
    let file: LargeFile
    let location: String

    var id: String { file.id }
    var name: String { file.url.lastPathComponent }
    var bytes: Int64 { file.bytes }
    var kind: String { file.kind }
    var lastOpenedSort: Date { file.lastOpened ?? .distantPast }
}

@MainActor @Observable
final class LargeFilesModel {
    static let thresholds: [Int64] = [50, 100, 250, 500, 1000].map { $0 * 1_000_000 }

    var state: ScanState = .idle
    var files: [LargeFile] = []
    var checked: Set<String> = []
    var minimumBytes: Int64 = 100_000_000
    var includeLibrary = false
    var search = ""
    var sortOrder = [KeyPathComparator(\LargeFileRow.bytes, order: .reverse)]

    private let engine = LargeFileEngine()
    private var task: Task<Void, Never>?

    var rows: [LargeFileRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let query = search.trimmingCharacters(in: .whitespaces)
        return files
            .filter { query.isEmpty || $0.url.path.localizedCaseInsensitiveContains(query) }
            .map { LargeFileRow(file: $0, location: Format.location($0.url.deletingLastPathComponent(), home: home)) }
            .sorted(using: sortOrder)
    }

    var totalBytes: Int64? { files.isEmpty ? nil : files.reduce(0) { $0 + $1.bytes } }
    var checkedBytes: Int64 { files.lazy.filter { self.checked.contains($0.id) }.reduce(0) { $0 + $1.bytes } }

    func scan() {
        task?.cancel()
        files = []
        checked = []
        state = .scanning(nil)
        let minimum = minimumBytes
        let library = includeLibrary
        task = Task {
            do {
                _ = try await engine.scan(minimumBytes: minimum, includeLibrary: library) { file in
                    Task { @MainActor in
                        guard self.state.isScanning else { return }
                        self.files.append(file)
                    }
                }
                // let the last appends land before marking the scan done.
                await Task.yield()
                state = .done(Date())
            } catch {
                state = Task.isCancelled || error is CancellationError ? .done(Date()) : .failed(error.localizedDescription)
            }
        }
    }

    func stop() { task?.cancel() }

    var checkedItems: [RemovalItem] {
        files.filter { checked.contains($0.id) }.map { RemovalItem(url: $0.url, bytes: $0.bytes) }
    }

    func didTrash(_ paths: Set<String>) {
        files.removeAll { paths.contains($0.id) }
        checked.subtract(paths)
    }
}
