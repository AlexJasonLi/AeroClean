import Foundation
import Testing
@testable import MacCleanerCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

struct MoleCleanListTests {
    let home = "/Users/fakehome"

    func items() throws -> [JunkItem] {
        MoleCleanList.parse(String(decoding: try fixture("clean-list.txt"), as: UTF8.self), home: home)
    }

    @Test func skipsNestedRowsTrashAndEmptyRows() throws {
        let paths = try items().map(\.url.path)
        #expect(!paths.contains("/Users/fakehome/Library/Caches/GeoServices/Resources"))
        #expect(!paths.contains { $0.contains("/.Trash") })
        #expect(!paths.contains("/Users/fakehome/Library/Caches/AMSDataMigratorTool"))
        #expect(paths.count == 9)
    }

    @Test func readsSizesCountsAndSections() throws {
        let byPath = Dictionary(uniqueKeysWithValues: try items().map { ($0.url.path, $0) })
        let geo = try #require(byPath["/Users/fakehome/Library/Caches/GeoServices"])
        #expect(geo.bytes == 135_700_000)
        #expect(geo.itemCount == 9)
        #expect(geo.section == "User essentials")
        #expect(byPath["/Users/fakehome/.cache/uv"]?.bytes == nil)
        #expect(byPath["/Users/fakehome/.cache/uv"]?.section == "Developer tools")
        #expect(byPath["/Users/fakehome/Library/Logs/Claude/main.log"]?.bytes == 4_000)
    }

    @Test func namesOwners() throws {
        let owners = Dictionary(uniqueKeysWithValues: try items().map { ($0.url.path, $0.owner) })
        #expect(owners["/Users/fakehome/Library/Caches/GeoServices"] == "GeoServices")
        #expect(owners["/Users/fakehome/Library/Logs/Claude/main.log"] == "Claude")
        #expect(owners["/Users/fakehome/.npm/_cacache"] == "npm")
        #expect(owners["/Users/fakehome/.cache/uv"] == "uv")
        #expect(owners["/Users/fakehome/Library/Developer/CoreSimulator/Devices/08697CB0/data/Library/Caches"] == "iOS Simulators")
        #expect(owners["/Users/fakehome/Notebook/round4/__pycache__"] == "Notebook")
        #expect(owners["/Users/fakehome/Library/Saved Application State/com.spotify.installer.savedState"] == "Saved app states")
        #expect(owners["/Users/fakehome/Library/Application Support/Adobe/Common/Media Cache Files/clip.ims"] == "Adobe")
    }

    @Test func parsesMoleSizeUnits() {
        #expect(MoleCleanList.parseSize("4KB") == 4_000)
        #expect(MoleCleanList.parseSize("2.66GB") == 2_660_000_000)
        #expect(MoleCleanList.parseSize("1B") == 1)
        #expect(MoleCleanList.parseSize("size unknown") == nil)
    }
}

struct SpaceEngineTests {
    @Test func decodesMoleAnalyzeJSON() throws {
        let listing = try SpaceEngine.decode(try fixture("analyze.json"))
        #expect(listing.isPartial)
        #expect(listing.entries.count == 4)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        #expect(byName["Library"]?.isPartial == true)
        #expect(byName["node_modules"]?.isCleanable == true)
        #expect(byName["clip.mov"]?.lastAccess != nil)
        #expect(byName["clip.mov"]?.isDirectory == false)
        #expect(byName["Locked"]?.bytes == 0)
    }
}

struct DuplicateEngineTests {
    let policy = SafetyPolicy(home: URL(fileURLWithPath: "/Users/fakehome"))

    @Test func dropsCopiesTheTrasherWouldRefuse() throws {
        let groups = try DuplicateEngine.decode(try fixture("fclones.json"), policy: policy)
        // the photo inside the photos library is not offered, which leaves one copy: no group.
        #expect(groups.count == 2)
        #expect(groups.first?.hash == "bbb")
        #expect(groups.first?.redundantBytes == 1_800_000_000)
    }

    @Test func suggestsKeepingTheShortestPathWithoutDates() throws {
        let groups = try DuplicateEngine.decode(try fixture("fclones.json"), policy: policy)
        let movie = try #require(groups.first { $0.hash == "bbb" })
        #expect(movie.suggestedKeeper?.url.path == "/Users/fakehome/Movies/a.mov")
    }
}
