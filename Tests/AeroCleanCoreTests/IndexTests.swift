import Foundation
import Testing
@testable import AeroCleanCore

struct IndexTests {
    func makeTree(_ root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("c"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3_000_000).write(to: root.appendingPathComponent("a/b/big.bin"))
        try Data(repeating: 2, count: 10_000).write(to: root.appendingPathComponent("a/small.txt"))
        try Data(repeating: 3, count: 3_000_000).write(to: root.appendingPathComponent("c/big copy.bin"))
        // a hard link must count once.
        try manager.linkItem(at: root.appendingPathComponent("a/b/big.bin"), to: root.appendingPathComponent("c/link.bin"))
    }

    @Test func sizesFoldersAndListsBigFiles() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try makeTree(sandbox.home)
        let index = FastScanner.scan(roots: [sandbox.home], bigFileMinimum: 1_000_000, threads: 4)

        #expect(index.totalFiles == 3)
        #expect(index.files.count == 2)
        let root = index.roots[0]
        #expect(index.path(of: root) == sandbox.home.path)
        let names = Set(index.files.map(\.name))
        #expect(names == ["big.bin", "big copy.bin"] || names == ["link.bin", "big copy.bin"])
        let a = try #require(index.folder(at: sandbox.home.appendingPathComponent("a").path))
        #expect(index.smallCounts[Int(a)] == 1)
        #expect(index.totals[Int(root)] >= 6_000_000)
        #expect(index.totals[Int(root)] < 7_000_000)
    }

    @Test func roundTripsThroughTheStore() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try makeTree(sandbox.home)
        let index = FastScanner.scan(roots: [sandbox.home], threads: 2)
        let store = IndexStore(fileURL: sandbox.root.appendingPathComponent("index.plist"))
        store.save(index)
        let loaded = try #require(store.load())
        #expect(loaded.totals == index.totals)
        #expect(loaded.files == index.files)
    }

    @Test func duplicateCandidatesShareALengthAndSkipAppData() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let manager = FileManager.default
        for folder in ["Movies", "Desktop", "Library/Caches", "proj/node_modules/x"] {
            try manager.createDirectory(at: sandbox.home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let payload = Data(repeating: 9, count: 2_000_000)
        for path in ["Movies/a.mov", "Desktop/a.mov", "Library/Caches/a.mov", "proj/node_modules/x/a.mov"] {
            try payload.write(to: sandbox.home.appendingPathComponent(path))
        }
        try Data(repeating: 9, count: 2_000_001).write(to: sandbox.home.appendingPathComponent("Desktop/other.mov"))
        let index = FastScanner.scan(roots: [sandbox.home], threads: 2)
        let candidates = DuplicateEngine.candidates(in: index, home: sandbox.home.path, minimumBytes: 1_000_000)
        #expect(Set(candidates.map { URL(fileURLWithPath: $0).lastPathComponent + "@" + URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent })
            == ["a.mov@Movies", "a.mov@Desktop"])
    }

    @Test func parsesApfsVolumes() throws {
        let plist: [String: Any] = ["Containers": [
            ["Volumes": [["Roles": ["Preboot"], "CapacityInUse": 5]]],
            ["Volumes": [
                ["Roles": ["System"], "CapacityInUse": 10],
                ["Roles": ["Data"], "CapacityInUse": 400],
                ["Roles": ["VM"], "CapacityInUse": 7],
                ["Roles": ["Preboot"], "CapacityInUse": 3],
            ]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let volumes = try #require(SystemProbe.parse(data))
        #expect(volumes.swap == 7)
        #expect(volumes.preboot == 3)
        #expect(volumes.system == 10)
    }
}

struct TemporaryFolderPolicyTests {
    let policy = SafetyPolicy(
        home: URL(fileURLWithPath: "/Users/fakehome"),
        extraRoots: [URL(fileURLWithPath: "/private/var/folders/zz/abc/T"), URL(fileURLWithPath: "/private/var/folders/zz/abc/X")]
    )

    @Test func allowsItemsInsideTheUsersTempFolders() {
        #expect(policy.verdict(for: URL(fileURLWithPath: "/private/var/folders/zz/abc/T/vc-eval-123")) == .allowed)
        #expect(policy.verdict(for: URL(fileURLWithPath: "/private/var/folders/zz/abc/X/com.google.Chrome.code_sign_clone")) == .allowed)
    }

    @Test func refusesTheFoldersThemselvesAndTheirNeighbours() {
        #expect(policy.verdict(for: URL(fileURLWithPath: "/private/var/folders/zz/abc/T")) != .allowed)
        #expect(policy.verdict(for: URL(fileURLWithPath: "/private/var/folders/zz/abc/C/com.apple.x")) != .allowed)
        #expect(policy.verdict(for: URL(fileURLWithPath: "/private/var/folders/zz/abc/T/repo/.git")) != .allowed)
    }

    @Test func trasherRefusesItemsInUse() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = sandbox.home.appendingPathComponent("com.example.running/cache.db")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        let trasher = Trasher(policy: SafetyPolicy(home: sandbox.home, extraRoots: []), log: nil) { url in
            url.path.contains("com.example.running") ? "Quit Example first" : nil
        }
        #expect(trasher.preflight(TrashRequest(url: file, bytes: 1)) == "Quit Example first")
    }
}

struct StdinTests {
    @Test func feedsStandardInput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/wc"), ["-l"], input: Data("a\nb\nc\n".utf8))
        #expect(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespaces).hasPrefix("3"))
    }
}
