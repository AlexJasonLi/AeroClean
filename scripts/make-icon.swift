// draws the app icon and writes an .icns. usage: swift scripts/make-icon.swift <out.icns>
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

// stormy morning palette: ink, slate, sky, mist.
let ink = color(0x384959)
let slate = color(0x6A89A7)
let sky = color(0x88BDF2)
let mist = color(0xBDDDFC)

func draw(size: Int) -> Data {
    let scale = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824pt body centred on a 1024pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    ink.setFill()
    NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()

    // a list sorted by size: four bars, longest on top, the last one marked for removal.
    let bars: [(CGFloat, NSColor)] = [(560, mist), (430, sky), (300, slate), (170, slate.withAlphaComponent(0.45))]
    let barHeight: CGFloat = 78
    let gap: CGFloat = 46
    let left: CGFloat = 232
    var top: CGFloat = 724
    for (width, fill) in bars {
        fill.setFill()
        NSRect(x: left, y: top - barHeight, width: width, height: barHeight).fill()
        top -= barHeight + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
