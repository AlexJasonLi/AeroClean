import AppKit

/// the app icon: a tiny pixel meadow under an aero glass dome, written as an .icns.
public enum IconRenderer {
    public static func writeIcns(to output: URL) throws {
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for base in [16, 32, 128, 256, 512] {
            try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
            try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try iconutil.run()
        iconutil.waitUntilExit()
    }

    static func png(size: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        let cg = context.cgContext
        let scale = CGFloat(size) / 1024
        cg.scaleBy(x: scale, y: scale)
        // macOS icon grid: an 824 point body centred on 1024.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // the meadow, drawn at 48 pixels across with hard edges.
        let scene = MeadowScene(kind: .dandelionHill, width: 48, height: 48, seed: 5)
        var frame = scene.frame(at: 2.4)
        // the scene's torn edge belongs to the app window, not the icon.
        let sky = Pixel(0x58A7EA).packed
        for i in frame.pixels.indices where frame.pixels[i] == 0 { frame.pixels[i] = i < frame.pixels.count / 2 ? sky : Pixel(0x3F8F43).packed }
        if let image = frame.makeImage() {
            cg.interpolationQuality = .none
            cg.draw(image, in: body)
        }
        // aero gloss over the top half.
        let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.0)])!
        let dome = NSBezierPath(ovalIn: CGRect(x: 150, y: 520, width: 724, height: 420))
        gloss.draw(in: dome, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.6).setStroke()
        shape.lineWidth = 6
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
