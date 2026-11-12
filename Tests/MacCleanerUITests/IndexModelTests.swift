import Foundation
import Testing
@testable import MacCleanerCore
@testable import MacCleanerUI

@MainActor
struct IndexModelTests {
    func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-model-\(UUID().uuidString)")
        for index in 0..<200 {
            let folder = root.appendingPathComponent("tree/\(index % 20)/\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("f"))
        }
        return root
    }

    @Test func stopEndsTheScanAndDropsItsResult() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IndexModel(home: root.path, roots: [root.appendingPathComponent("tree")],
                               store: IndexStore(fileURL: root.appendingPathComponent("index.plist")))
        model.scan()
        #expect(model.state.isScanning)
        model.stop()
        #expect(!model.state.isScanning)
        #expect(model.state == .idle)
        // the stopped scan finishes in the background; its result must not land.
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.index == nil)
    }

    @Test func aFinishedScanLandsAndStopKeepsIt() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = IndexModel(home: root.path, roots: [root.appendingPathComponent("tree")],
                               store: IndexStore(fileURL: root.appendingPathComponent("index.plist")))
        model.scan()
        for _ in 0..<50 where model.state.isScanning { try await Task.sleep(for: .milliseconds(100)) }
        let first = try #require(model.index)
        #expect(first.totalFiles == 200)
        model.scan()
        model.stop()
        if case .done(let date) = model.state { #expect(date == first.scannedAt) } else { Issue.record("expected done") }
        #expect(model.index?.scannedAt == first.scannedAt)
    }
}
