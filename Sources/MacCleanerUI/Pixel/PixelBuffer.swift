import CoreGraphics
import Foundation

/// a colour packed the way the bitmap stores it: bytes r, g, b, a in memory.
struct Pixel: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8 = 255

    init(_ hex: UInt32, alpha: UInt8 = 255) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
        a = alpha
    }

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var packed: UInt32 {
        // premultiplied, so a transparent pixel is all zero.
        let alpha = UInt32(a)
        let pr = UInt32(r) * alpha / 255
        let pg = UInt32(g) * alpha / 255
        let pb = UInt32(b) * alpha / 255
        return pr | (pg << 8) | (pb << 16) | (alpha << 24)
    }

    /// straight blend toward another colour, t in 0...1.
    func mixed(_ other: Pixel, _ t: Double) -> Pixel {
        let t = min(max(t, 0), 1)
        func lerp(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) + (Double(b) - Double(a)) * t) }
        return Pixel(r: lerp(r, other.r), g: lerp(g, other.g), b: lerp(b, other.b), a: lerp(a, other.a))
    }
}

/// 4x4 ordered dither thresholds, the classic bayer pattern that gives skies their cross-hatch.
enum Bayer {
    private static let matrix: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }

    static func threshold(_ x: Int, _ y: Int) -> Double {
        matrix[(y & 3) * 4 + (x & 3)]
    }

    /// picks between two colours so that, on average, a fraction `t` shows `b`.
    static func pick(_ a: Pixel, _ b: Pixel, _ t: Double, _ x: Int, _ y: Int) -> Pixel {
        t > threshold(x, y) ? b : a
    }

    /// walks a ramp of colours; `v` runs 0...ramp.count-1 and is dithered between steps.
    static func ramp(_ colors: [Pixel], _ v: Double, _ x: Int, _ y: Int) -> Pixel {
        let clamped = min(max(v, 0), Double(colors.count - 1))
        let index = Int(clamped)
        if index >= colors.count - 1 { return colors[colors.count - 1] }
        return pick(colors[index], colors[index + 1], clamped - Double(index), x, y)
    }
}

/// small deterministic random numbers, so a scene looks the same every launch.
struct Rand {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(max(hi - lo + 1, 1))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

/// stable per-pixel noise in 0..<1.
@inline(__always)
func hash01(_ x: Int, _ y: Int, _ salt: Int = 0) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ salt &* 2_147_483_647))
    h = (h ^ (h >> 13)) &* 0x5BD1_E995
    h ^= h >> 15
    return Double(h & 0xFFFF) / 65536
}

/// a tiny rgba canvas. scenes are drawn at a few hundred pixels across and shown scaled up.
struct PixelBuffer {
    let width: Int
    let height: Int
    var pixels: [UInt32]

    init(width: Int, height: Int, fill: UInt32 = 0) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        pixels = Array(repeating: fill, count: self.width * self.height)
    }

    @inline(__always)
    mutating func set(_ x: Int, _ y: Int, _ color: Pixel) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color.packed
    }

    @inline(__always)
    mutating func setPacked(_ x: Int, _ y: Int, _ value: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = value
    }

    @inline(__always)
    func packed(_ x: Int, _ y: Int) -> UInt32 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Pixel) {
        let packedColor = color.packed
        for yy in max(y, 0)..<min(y + h, height) {
            for xx in max(x, 0)..<min(x + w, width) { pixels[yy * width + xx] = packedColor }
        }
    }

    /// clears pixels near the edges with a noisy threshold, for the torn pixel border.
    mutating func raggedEdges(depth: Int, salt: Int = 7) {
        guard depth > 0 else { return }
        for y in 0..<height {
            for x in 0..<width {
                let edge = min(x, y, width - 1 - x, height - 1 - y)
                guard edge < depth else { continue }
                let keep = Double(edge + 1) / Double(depth + 1)
                // two octaves so the edge has both bites and specks.
                let noise = hash01(x / 2, y / 2, salt) * 0.6 + hash01(x, y, salt + 1) * 0.4
                if noise > keep { pixels[y * width + x] = 0 }
            }
        }
    }

    func makeImage() -> CGImage? {
        let bytesPerRow = width * 4
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
