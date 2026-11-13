import Foundation
import AeroCleanCore
import AeroCleanUI

// usage: Snapshots scenes <folder> | Snapshots screens <folder> | Snapshots index <path> [threads]
let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "scenes"
let output = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "snapshots")
switch mode {
case "index":
    let root = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : NSHomeDirectory())
    let threads = arguments.count > 3 ? Int(arguments[3]) ?? 16 : 16
    let index = FastScanner.scan(roots: [root], threads: threads)
    print(String(format: "%.2fs  %d folders  %lld files  %.2f GB  %d big files",
                 index.duration, index.names.count, index.totalFiles, Double(index.totalBytes) / 1e9, index.files.count))
case "icon":
    try IconRenderer.writeIcns(to: output)
    print("wrote \(output.path)")
case "screens":
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        do { try await ScreenSnapshot.render(to: output) } catch { print("failed: \(error)") }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    print("wrote \(output.path)")
default:
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for kind in SceneKind.allCases {
        if let data = SceneSnapshot.png(kind: kind, width: 320, height: 96, scale: 3, time: 3.2) {
            try data.write(to: output.appendingPathComponent("scene-\(kind).png"))
        }
    }
    print("wrote \(output.path)")
}
