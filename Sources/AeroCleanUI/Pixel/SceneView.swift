import AppKit
import SwiftUI

/// keeps one scene per kind and size, and dissolves pixel by pixel when the kind changes.
@MainActor
final class SceneRenderer {
    private var scenes: [String: MeadowScene] = [:]
    private var previous: (scene: MeadowScene, until: Double)?
    private var currentKey = ""
    private let started = Date()
    static let dissolve = 0.7

    func time(_ date: Date) -> Double { date.timeIntervalSince(started) }

    func scene(_ kind: SceneKind, width: Int, height: Int) -> MeadowScene {
        let key = "\(kind.rawValue)-\(width)x\(height)"
        if let scene = scenes[key] { return scene }
        let scene = MeadowScene(kind: kind, width: width, height: height)
        // a resize throws away the other sizes of this kind.
        scenes = scenes.filter { !$0.key.hasPrefix("\(kind.rawValue)-") }
        scenes[key] = scene
        return scene
    }

    func image(kind: SceneKind, width: Int, height: Int, time t: Double, wind: Double) -> CGImage? {
        let scene = scene(kind, width: width, height: height)
        let key = "\(kind.rawValue)-\(width)x\(height)"
        if key != currentKey {
            if let old = scenes[currentKey], old.width == width, old.height == height {
                previous = (old, t + Self.dissolve)
            }
            currentKey = key
        }
        scene.wind += (wind - scene.wind) * 0.08
        var frame = scene.frame(at: t)
        if let previous, t < previous.until {
            // each pixel flips to the new scene at its own moment: a pixel dissolve.
            let progress = 1 - (previous.until - t) / Self.dissolve
            let old = previous.scene.frame(at: t)
            for y in 0..<height {
                for x in 0..<width where hash01(x, y, 99) > progress {
                    frame.pixels[y * width + x] = old.pixels[y * width + x]
                }
            }
        } else {
            previous = nil
        }
        return frame.makeImage()
    }

    func burst(_ kind: SceneKind, width: Int, height: Int, at point: CGPoint, time: Double) {
        scene(kind, width: width, height: height).burst(at: (Double(point.x), Double(point.y)), time: time)
    }
}

/// an animated pixel scene with torn pixel edges. it fills its frame at a fixed pixel size,
/// so pixels stay square and crisp at any window size.
struct SceneView: View {
    let kind: SceneKind
    var wind: Double = 1
    var pixel: CGFloat = 3
    /// a fixed time, for snapshots; nil animates.
    var still: Double? = nil
    /// changing it scatters petals across the scene, e.g. after a removal.
    var burstToken = 0
    @State private var renderer = SceneRenderer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        GeometryReader { proxy in
            let width = max(Int(proxy.size.width / pixel), 32)
            let height = max(Int(proxy.size.height / pixel), 24)
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: still != nil || reduceMotion || activeState == .inactive)) { timeline in
                let t = still ?? (reduceMotion ? 4 : renderer.time(timeline.date))
                if let image = renderer.image(kind: kind, width: width, height: height, time: t, wind: wind) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(width) * pixel, height: CGFloat(height) * pixel)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .onChange(of: burstToken) {
                let t = renderer.time(Date())
                for spot in 0..<5 {
                    let x = CGFloat(width) * (0.15 + 0.17 * CGFloat(spot))
                    renderer.burst(kind, width: width, height: height, at: CGPoint(x: x, y: CGFloat(height) * 0.65), time: t)
                }
            }
            .onTapGesture { location in
                renderer.burst(kind, width: width, height: height,
                               at: CGPoint(x: location.x / pixel, y: location.y / pixel), time: renderer.time(Date()))
            }
        }
        .accessibilityHidden(true)
    }
}
