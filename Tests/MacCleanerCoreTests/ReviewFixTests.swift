import Darwin
import Foundation
import Testing
@testable import MacCleanerCore

struct SurvivorTests {
    @Test func keepsADuplicateWhenItsOtherCopyIsGone() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let a = sandbox.home.appendingPathComponent("a.mov")
        let b = sandbox.home.appendingPathComponent("Clips/a.mov")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: a)

        // b was removed elsewhere: a must stay.
        let request = TrashRequest(url: a, bytes: 100, survivors: [b])
        #expect(sandbox.trasher.preflight(request) == "Its other copies are gone, so this one was kept")

        // b is back but a different size: still not a copy.
        try Data(repeating: 1, count: 99).write(to: b)
        #expect(sandbox.trasher.preflight(request) != nil)

        try Data(repeating: 1, count: 100).write(to: b)
        #expect(sandbox.trasher.preflight(request) == nil)
    }

    @Test func neverRemovesEveryCopyInOneBatch() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let a = sandbox.home.appendingPathComponent("a.bin")
        let b = sandbox.home.appendingPathComponent("b.bin")
        try Data(repeating: 2, count: 64).write(to: a)
        try Data(repeating: 2, count: 64).write(to: b)

        let outcome = sandbox.trasher.trash([
            TrashRequest(url: a, bytes: 64, survivors: [b]),
            TrashRequest(url: b, bytes: 64, survivors: [a]),
        ])
        #expect(outcome.moved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    @Test func coversPathsAndTheirContents() {
        let removed: Set<String> = ["/h/a", "/h/b c"]
        #expect(Trasher.covers(removed, "/h/a"))
        #expect(Trasher.covers(removed, "/h/a/x/y"))
        #expect(Trasher.covers(removed, "/h/b c/z"))
        #expect(!Trasher.covers(removed, "/h/ab"))
        #expect(!Trasher.covers(removed, "/h/b"))
    }
}

struct FolderContentTests {
    @Test func refusesAFolderHoldingAMediaLibrary() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let archive = sandbox.home.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(
            at: archive.appendingPathComponent("2019/Old Photos.photoslibrary/originals"),
            withIntermediateDirectories: true
        )
        let reason = sandbox.trasher.preflight(TrashRequest(url: archive, bytes: 1))
        #expect(reason?.contains("Old Photos.photoslibrary") == true)
    }

    @Test func allowsAProjectFolderAndReportsItsGitHistory() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let project = sandbox.home.appendingPathComponent("OldProject")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        #expect(sandbox.trasher.preflight(TrashRequest(url: project, bytes: 1)) == nil)
        #expect(FolderInspector.inspect(project).gitRepositories == 1)
    }

    @Test func stopsAtTheLimit() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        for index in 0..<30 { try Data().write(to: sandbox.home.appendingPathComponent("f\(index)")) }
        #expect(FolderInspector.inspect(sandbox.home, limit: 10).truncated)
        #expect(!FolderInspector.inspect(sandbox.home, limit: 100).truncated)
    }
}

struct CredentialTests {
    let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/fakehome"), extraRoots: [])

    @Test(arguments: [
        "/Users/fakehome/.docker/config.json",
        "/Users/fakehome/.netrc",
        "/Users/fakehome/.git-credentials",
        "/Users/fakehome/.config/gh/hosts.yml",
        "/Users/fakehome/.config/gcloud/credentials.db",
        "/Users/fakehome/Pictures/Lightroom/Catalog.lrcat",
        "/Users/fakehome/Pictures/Lightroom/Catalog Previews.lrdata/0/a.lrprev",
        "/Users/fakehome/Music/Song.band",
    ])
    func refuses(_ path: String) {
        #expect(policy.verdict(for: URL(fileURLWithPath: path)) != .allowed)
    }

    @Test func stillAllowsToolLogs() {
        #expect(policy.verdict(for: URL(fileURLWithPath: "/Users/fakehome/.config/gcloud/logs")) == .allowed)
        #expect(policy.verdict(for: URL(fileURLWithPath: "/Users/fakehome/.docker-old/image.tar")) == .allowed)
    }
}

struct ProcessRunnerTests {
    @Test func cancellingStopsTheToolAndItsHelpers() async throws {
        let helper = LockedList<String>()
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30 & echo $!; wait"]) { helper.append($0) }
        }
        while helper.items.isEmpty, Date().timeIntervalSince(started) < 5 { try await Task.sleep(for: .milliseconds(50)) }
        let helperPID = try #require(helper.items.first.flatMap { pid_t($0) })
        task.cancel()
        _ = try? await task.value
        #expect(Date().timeIntervalSince(started) < 8)
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(helperPID, 0) != 0, "the background sleep should be gone")
    }

    @Test func returnsWhenAHelperKeepsTheOutputOpen() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo hi; (sleep 30 &); exit 0"])
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hi\n")
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func reportsExitCodesAndStderr() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.stderr == "oops\n")
    }
}
