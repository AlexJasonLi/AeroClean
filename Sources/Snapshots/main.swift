import Foundation
import MacCleanerCore
import MacCleanerUI

// usage: Snapshots scenes <folder> | Snapshots index <path> [threads]
let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "scenes" {
case "index":
    let root = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : NSHomeDirectory())
    let threads = arguments.count > 3 ? Int(arguments[3]) ?? 16 : 16
    let index = FastScanner.scan(roots: [root], threads: threads)
    let unreadable = index.unreadable.filter { $0 }.count
    print(String(format: "%.2fs  %d folders  %lld files  %.2f GB  %d big files  %d unreadable",
                 index.duration, index.names.count, index.totalFiles, Double(index.totalBytes) / 1e9, index.files.count, unreadable))
    let kids = index.childFolders[Int(index.roots[0])].sorted { index.totals[Int($0)] > index.totals[Int($1)] }
    for child in kids.prefix(8) {
        print(String(format: "  %7.2f GB  %@", Double(index.totals[Int(child)]) / 1e9, index.names[Int(child)]))
    }
default:
    let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "snapshots")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for kind in SceneKind.allCases {
        if let data = SceneSnapshot.png(kind: kind, width: 320, height: 96, scale: 3, time: 3.2) {
            try data.write(to: output.appendingPathComponent("scene-\(kind).png"))
        }
    }
    print("wrote \(output.path)")
}
