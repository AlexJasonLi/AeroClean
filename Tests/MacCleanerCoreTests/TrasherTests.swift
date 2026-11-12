import Foundation
import Testing
@testable import MacCleanerCore

@Suite(.serialized)
struct TrasherTests {
    @Test func collapseDropsRequestsInsideOtherRequests() {
        let requests = [
            TrashRequest(url: URL(fileURLWithPath: "/h/a/b/c"), bytes: 1),
            TrashRequest(url: URL(fileURLWithPath: "/h/a"), bytes: 10),
            TrashRequest(url: URL(fileURLWithPath: "/h/a b"), bytes: 5),
            TrashRequest(url: URL(fileURLWithPath: "/h/a b/c"), bytes: 1),
            TrashRequest(url: URL(fileURLWithPath: "/h/ab"), bytes: 2),
        ]
        let kept = Trasher.collapse(requests).map(\.url.path)
        #expect(kept == ["/h/a", "/h/a b", "/h/ab"])
    }

    @Test func refusesWithoutTouchingTheFile() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let outside = sandbox.root.appendingPathComponent("outside.bin")
        try Data("keep".utf8).write(to: outside)
        let ssh = sandbox.home.appendingPathComponent(".ssh/id_ed25519")
        try FileManager.default.createDirectory(at: ssh.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("key".utf8).write(to: ssh)

        let outcome = sandbox.trasher.trash([
            TrashRequest(url: outside, bytes: 4),
            TrashRequest(url: ssh, bytes: 3),
            TrashRequest(url: sandbox.home.appendingPathComponent("gone.bin"), bytes: 1),
        ])

        #expect(outcome.moved.isEmpty)
        #expect(outcome.failed.count == 3)
        #expect(outcome.failed.map(\.reason).contains("No longer exists"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: ssh.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.log.fileURL.path))
    }

    @Test func movesAllowedItemsToTheTrashAndLogsThem() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = sandbox.home.appendingPathComponent("maccleaner-test-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: 2048).write(to: file)

        let outcome = sandbox.trasher.trash([TrashRequest(url: file, bytes: 2048)])

        #expect(outcome.failed.isEmpty)
        #expect(outcome.bytesMoved == 2048)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let log = try String(contentsOf: sandbox.log.fileURL, encoding: .utf8)
        #expect(log.contains(file.path))
        #expect(log.contains("\t2048\t"))
        // tidy up the copy the test put in the user's trash, if macOS lets us.
        if let inTrash = outcome.moved.first?.inTrash { try? FileManager.default.removeItem(at: inTrash) }
    }
}

struct Sandbox {
    let root: URL
    let home: URL
    let log: RemovalLog
    let trasher: Trasher

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccleaner-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        log = RemovalLog(fileURL: root.appendingPathComponent("logs/removals.log"))
        trasher = Trasher(policy: SafetyPolicy(home: home, extraRoots: []), log: log)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
