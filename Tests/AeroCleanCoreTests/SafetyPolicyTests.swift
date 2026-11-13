import Foundation
import Testing
@testable import AeroCleanCore

struct SafetyPolicyTests {
    let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/fakehome"), extraRoots: [])

    func verdict(_ path: String) -> SafetyPolicy.Verdict {
        policy.verdict(for: URL(fileURLWithPath: path))
    }

    @Test(arguments: [
        "/Users/fakehome/Downloads/movie.mov",
        "/Users/fakehome/Downloads/Old Folder",
        "/Users/fakehome/Library/Caches/com.example.app",
        "/Users/fakehome/Library/Caches/com.example.app/blob",
        "/Users/fakehome/Library/Application Support/Adobe/Common/Media Cache Files/clip.ims",
        "/Users/fakehome/Library/Developer/CoreSimulator/Devices/ABC/data",
        "/Users/fakehome/project/node_modules",
        "/Users/fakehome/.cache/uv",
        "/Users/fakehome/.local/share/claude/versions/1.0.0",
        "/Users/fakehome/.config/gcloud/logs",
        "/Users/fakehome/Applications/Old.app",
    ])
    func allows(_ path: String) {
        #expect(verdict(path) == .allowed)
    }

    @Test(arguments: [
        "/Users/fakehome",
        "/Users/fakehome/",
        "/Users/fakehome/Downloads",
        "/Users/fakehome/Desktop/",
        "/Users/fakehome/Library",
        "/Users/fakehome/Library/Caches",
        "/Users/fakehome/Library/Application Support",
        "/Users/fakehome/.Trash",
        "/Users/fakehome/.Trash/old.zip",
        "/Users/fakehome/.ssh/id_ed25519",
        "/Users/fakehome/.aws/credentials",
        "/Users/fakehome/.config",
        "/Users/fakehome/Library/Keychains/login.keychain-db",
        "/Users/fakehome/Library/Mobile Documents/com~apple~CloudDocs/report.pdf",
        "/Users/fakehome/Library/CloudStorage/Dropbox/a.mov",
        "/Users/fakehome/Library/Mail/V10/inbox",
        "/Users/fakehome/Library/Messages/Attachments/a.heic",
        "/Users/fakehome/project/.git",
        "/Users/fakehome/project/.git/objects/pack/a.pack",
        "/Users/fakehome/Pictures/Photos Library.photoslibrary",
        "/Users/fakehome/Pictures/Photos Library.photoslibrary/originals/x.heic",
        "/Users/fakehome/Music/Music Library.musiclibrary",
        "/Users/fakehome/Movies/Edit.fcpbundle/Render Files/a.mov",
        "/etc/hosts",
        "/Users/someoneelse/Downloads/a.mov",
        "/Users/fakehome2/Downloads/a.mov",
        "/Users/fakehome/../someoneelse/a.mov",
        "/Users/fakehome/Downloads/../../someoneelse/a.mov",
        "/",
    ])
    func refuses(_ path: String) {
        #expect(verdict(path) != .allowed, "\(path) should be refused")
    }

    @Test func refusesNonFileURLs() {
        #expect(policy.verdict(for: URL(string: "https://example.com/a")!) != .allowed)
    }

    @Test func refusesInsideRealBundlesButNotLookalikeFolders() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let app = sandbox.home.appendingPathComponent("Applications/Old.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("Contents/Info.plist"))
        let cache = sandbox.home.appendingPathComponent("Library/Caches/com.example.app")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let policy = SafetyPolicy(home: sandbox.home, extraRoots: [])
        #expect(policy.verdict(for: app) == .allowed)
        #expect(policy.verdict(for: app.appendingPathComponent("Contents/MacOS/Old")) != .allowed)
        #expect(policy.verdict(for: cache.appendingPathComponent("blob")) == .allowed)
    }

    @Test func judgesSymlinksAsLinksAndResolvesParents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let policy = SafetyPolicy(home: home, extraRoots: [])
        // the link lives in the home folder, so trashing the link itself is fine.
        #expect(policy.verdict(for: link) == .allowed)
        // a path through the link lands outside the home folder.
        #expect(policy.verdict(for: link.appendingPathComponent("file")) != .allowed)
    }
}
