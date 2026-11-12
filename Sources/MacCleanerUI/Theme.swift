import AppKit
import CoreText
import SwiftUI

/// colours, type and shapes. one place, so every screen reads as the same object.
enum Theme {
    static let ink = Color(hex: 0x1D2B3A)
    static let inkSoft = Color(hex: 0x5B6E80)
    static let inkFaint = Color(hex: 0x93A4B4)
    static let mist = Color(hex: 0xF2F7FA)
    static let card = Color.white
    static let hairline = Color(hex: 0xDCE7EF)
    static let rowHover = Color(hex: 0xEEF6FC)
    static let rowSelected = Color(hex: 0xE0EFFA)
    static let aqua = Color(hex: 0x2FA8F5)
    static let aquaDeep = Color(hex: 0x0B78D0)
    static let aquaLight = Color(hex: 0x9BDDFF)
    static let leaf = Color(hex: 0x4BAE4F)
    static let petal = Color(hex: 0xEE6FA6)
    static let sun = Color(hex: 0xFFC93A)
    static let warn = Color(hex: 0xE8833A)

    /// departure mono, a pixel font. crisp at multiples of 11.
    static func pixel(_ size: CGFloat) -> Font {
        FontLoader.registerOnce()
        return .custom("DepartureMono-Regular", size: size)
    }

    static let body = Font.system(size: 13, weight: .medium)
    static let detail = Font.system(size: 11)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum FontLoader {
    nonisolated(unsafe) private static var done = false

    /// the font ships in the app bundle; during development it is read from the repo.
    static func registerOnce() {
        guard !done else { return }
        done = true
        let bundled = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "otf")
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/DepartureMono-Regular.otf")
        for url in [bundled, repo].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            return
        }
    }
}

/// a rectangle whose corners step like a pixel-art circle instead of curving.
struct PixelCorners: Shape {
    var radius: CGFloat = 9
    var step: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        // too small to step: a plain rectangle.
        guard r >= step, rect.width.isFinite, rect.height.isFinite else { return Path(rect) }
        let n = max(Int(r / step), 1)
        // inset of each step row from the straight edge, rasterised from a quarter circle.
        let insets: [CGFloat] = (0..<n).map { i in
            let y = r - (CGFloat(i) + 0.5) * step
            let x = r - (r * r - y * y).squareRoot()
            return (x / step).rounded() * step
        }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + insets[0], y: rect.minY))
        // top edge to the top right corner.
        path.addLine(to: CGPoint(x: rect.maxX - insets[0], y: rect.minY))
        for i in 0..<n {
            path.addLine(to: CGPoint(x: rect.maxX - insets[i], y: rect.minY + CGFloat(i + 1) * step))
            if i + 1 < n { path.addLine(to: CGPoint(x: rect.maxX - insets[i + 1], y: rect.minY + CGFloat(i + 1) * step)) }
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - CGFloat(n) * step))
        for i in (0..<n).reversed() {
            path.addLine(to: CGPoint(x: rect.maxX - insets[i], y: rect.maxY - CGFloat(i + 1) * step))
            path.addLine(to: CGPoint(x: rect.maxX - insets[i], y: rect.maxY - CGFloat(i) * step))
        }
        path.addLine(to: CGPoint(x: rect.minX + insets[0], y: rect.maxY))
        for i in 0..<n {
            path.addLine(to: CGPoint(x: rect.minX + insets[i], y: rect.maxY - CGFloat(i + 1) * step))
            if i + 1 < n { path.addLine(to: CGPoint(x: rect.minX + insets[i + 1], y: rect.maxY - CGFloat(i + 1) * step)) }
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + CGFloat(n) * step))
        for i in (0..<n).reversed() {
            path.addLine(to: CGPoint(x: rect.minX + insets[i], y: rect.minY + CGFloat(i + 1) * step))
            path.addLine(to: CGPoint(x: rect.minX + insets[i], y: rect.minY + CGFloat(i) * step))
        }
        path.closeSubpath()
        return path
    }
}

/// frosted aero glass: translucent white, a gloss on the upper half, a bright rim.
struct Glass: ViewModifier {
    var radius: CGFloat = 12
    var opacity: Double = 0.78

    func body(content: Content) -> some View {
        let shape = PixelCorners(radius: radius)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.white.opacity(opacity))
                    shape.fill(LinearGradient(
                        stops: [.init(color: .white.opacity(0.85), location: 0), .init(color: .white.opacity(0), location: 0.5)],
                        startPoint: .top, endPoint: .bottom
                    ))
                }
                .shadow(color: Color(hex: 0x3D6A8F, opacity: 0.18), radius: 14, y: 6)
            }
            .overlay { shape.stroke(Color.white, lineWidth: 1).padding(0.5) }
            .overlay { shape.stroke(Color(hex: 0xB9CEDD, opacity: 0.8), lineWidth: 0.5) }
    }
}

extension View {
    func glass(radius: CGFloat = 12, opacity: Double = 0.78) -> some View {
        modifier(Glass(radius: radius, opacity: opacity))
    }
}

/// a glossy aqua bubble, the aero button. `lit` is the active state.
struct Bubble<Content: View>: View {
    var size: CGFloat
    var lit: Bool
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: lit ? [Color(hex: 0x8FDBFF), Color(hex: 0x1E92E8)] : [Color.white, Color(hex: 0xE3EEF6)],
                startPoint: .top, endPoint: .bottom
            ))
            Circle().fill(RadialGradient(
                colors: [lit ? Color(hex: 0xC8F3FF, opacity: 0.9) : Color.white.opacity(0.9), .clear],
                center: .init(x: 0.5, y: 1.05), startRadius: 0, endRadius: size * 0.55
            ))
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(lit ? 0.85 : 0.95), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.74, height: size * 0.46)
                .offset(y: -size * 0.2)
            Circle().stroke(lit ? Color(hex: 0x0D6FBF, opacity: 0.55) : Color(hex: 0xB4C7D6), lineWidth: 1)
            content
        }
        .frame(width: size, height: size)
        .shadow(color: lit ? Color(hex: 0x1E92E8, opacity: 0.35) : Color(hex: 0x3D6A8F, opacity: 0.18), radius: lit ? 7 : 4, y: 2)
    }
}

/// a small pixel icon drawn from a bitmap: '#' is ink, anything else is empty.
struct PixelGlyph: View {
    let glyph: Glyph
    var cell: CGFloat = 2
    var color: Color = Theme.ink

    var body: some View {
        let rows = glyph.rows
        let width = rows.map(\.count).max() ?? 0
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, char) in row.enumerated() where char == "#" {
                    context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(width) * cell, height: CGFloat(rows.count) * cell)
        .accessibilityHidden(true)
    }
}

enum Glyph {
    case sparkle, weight, copies, folder, computer, scan, trash, check, dash, lock, chevronRight, chevronDown, back, close, info, leaf

    var rows: [String] {
        switch self {
        case .sparkle: [
                ".....#.....",
                ".....#.....",
                "....###....",
                "...#####...",
                "###########",
                ".#########.",
                "...#####...",
                "....###....",
                ".....#.....",
                ".....#.....",
                ".....#.....",
            ]
        case .weight: [
                "...#####...",
                "..##...##..",
                "..#.....#..",
                ".#########.",
                "###########",
                "####...####",
                "###.....###",
                "####...####",
                "###########",
                ".#########.",
                "...........",
            ]
        case .copies: [
                "#######....",
                "#.....#....",
                "#.....#....",
                "#...#######",
                "#...#.....#",
                "#...#.....#",
                "#####.....#",
                "....#.....#",
                "....#.....#",
                "....#######",
                "...........",
            ]
        case .folder: [
                "...........",
                "####.......",
                "#..#######.",
                "#........#.",
                "###########",
                "#.........#",
                "#.........#",
                "#.........#",
                "#.........#",
                "###########",
                "...........",
            ]
        case .computer: [
                "###########",
                "#.........#",
                "#.#####...#",
                "#.........#",
                "#.###.....#",
                "#.........#",
                "###########",
                "....###....",
                "....###....",
                "..#######..",
                "...........",
            ]
        case .scan: [
                "..#####....",
                ".#.....#...",
                "#.......#..",
                "#..##...#..",
                "#..#....#..",
                "#.......#..",
                ".#.....#...",
                "..######...",
                ".......###.",
                "........###",
                ".........#.",
            ]
        case .trash: [
                "....###....",
                "###########",
                "...........",
                ".#########.",
                ".#.#.#.#.#.",
                ".#.#.#.#.#.",
                ".#.#.#.#.#.",
                ".#.#.#.#.#.",
                ".#.#.#.#.#.",
                "..#######..",
                "...........",
            ]
        case .check: [
                ".......",
                "......#",
                ".....##",
                "#...##.",
                "##.##..",
                ".###...",
                "..#....",
            ]
        case .dash: [".......", ".......", ".......", "#######", ".......", ".......", "......."]
        case .lock: [
                "..###..",
                ".#...#.",
                ".#...#.",
                "#######",
                "###.###",
                "###.###",
                "#######",
            ]
        case .chevronRight: ["#...", "##..", ".##.", "..##", ".##.", "##..", "#..."]
        case .chevronDown: ["#.....#", "##...##", ".##.##.", "..###..", "...#..."]
        case .back: ["...#", "..##", ".##.", "##..", ".##.", "..##", "...#"]
        case .close: ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
        case .info: [".###.", ".....", ".###.", "..##.", "..##.", "..##.", ".####"]
        case .leaf: [
                "......####.",
                "....######.",
                "..########.",
                ".####.####.",
                ".###.#####.",
                "####.####..",
                "###.####...",
                "##.###.....",
                "#..........",
            ]
        }
    }
}

/// the pixel checkbox. nil means mixed.
struct PixelCheck: View {
    var state: Bool?
    var locked = false
    var disabled = false

    var body: some View {
        let shape = PixelCorners(radius: 4, step: 2)
        ZStack {
            if locked {
                PixelGlyph(glyph: .lock, cell: 1.5, color: Theme.inkFaint)
            } else {
                shape.fill(state != false
                    ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x6ECDFF), Theme.aquaDeep], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.white))
                shape.stroke(state != false ? Color(hex: 0x0B67B3) : Color(hex: 0xAFC3D3), lineWidth: 1)
                if state == true { PixelGlyph(glyph: .check, cell: 1.5, color: .white) }
                if state == nil { PixelGlyph(glyph: .dash, cell: 1.5, color: .white) }
            }
        }
        .frame(width: 16, height: 16)
        .opacity(disabled ? 0.35 : 1)
        .contentShape(Rectangle())
    }
}

/// a bar made of square cells, filled from the left.
struct PixelBar: View {
    var fraction: Double
    var cells = 12
    var cell: CGFloat = 4
    var gap: CGFloat = 1
    var fill: Color = Theme.aqua
    var empty: Color = Color(hex: 0xE3ECF3)

    var body: some View {
        let filled = Int((min(max(fraction, 0), 1) * Double(cells)).rounded(.up))
        HStack(spacing: gap) {
            ForEach(0..<cells, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? fill : empty)
                    .frame(width: cell, height: cell)
            }
        }
        .accessibilityHidden(true)
    }
}

/// a small pixel-type capsule used for filters and breadcrumbs.
struct Chip: View {
    let title: String
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.pixel(11))
                .foregroundStyle(lit ? Color.white : Theme.inkSoft)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background {
                    PixelCorners(radius: 6, step: 2)
                        .fill(lit
                            ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x6ECDFF), Theme.aquaDeep], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color(hex: 0xF0F5F9)))
                }
                .overlay { PixelCorners(radius: 6, step: 2).stroke(lit ? Color(hex: 0x0B67B3, opacity: 0.6) : Theme.hairline, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

/// the primary aero action: a glossy aqua capsule.
struct AquaButton: View {
    let title: String
    var glyph: Glyph? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let glyph { PixelGlyph(glyph: glyph, cell: 1.5, color: .white) }
                Text(title).font(Theme.pixel(11)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background {
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0x7FD4FF), Color(hex: 0x1683DC)], startPoint: .top, endPoint: .bottom))
                    Capsule()
                        .fill(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .padding(.bottom, 15)
                    Capsule().stroke(Color(hex: 0x0D64AD, opacity: 0.6), lineWidth: 1)
                }
                .shadow(color: Color(hex: 0x1683DC, opacity: 0.35), radius: 6, y: 3)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}
