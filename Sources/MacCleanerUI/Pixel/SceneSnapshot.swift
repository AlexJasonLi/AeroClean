import AppKit
import Foundation

/// renders a scene frame to png, scaled with hard pixel edges. used by the snapshot tool.
public enum SceneSnapshot {
    public static func png(kind: SceneKind, width: Int, height: Int, scale: Int, time: Double) -> Data? {
        let scene = MeadowScene(kind: kind, width: width, height: height)
        guard let image = scene.frame(at: time).makeImage() else { return nil }
        let size = NSSize(width: width * scale, height: height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.cgContext.interpolationQuality = .none
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        context.cgContext.draw(image, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
