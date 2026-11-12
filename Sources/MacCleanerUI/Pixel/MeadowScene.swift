import Foundation

/// the five places the app's panes open onto. original scenes, drawn entirely in code.
public enum SceneKind: Int, CaseIterable, Sendable {
    /// spring hill of dandelion clocks shedding seeds on the wind.
    case dandelionHill
    /// summer ridge with one old tree and towering clouds.
    case summerRidge
    /// a still pond that doubles the sky.
    case stillPond
    /// valley of patchwork fields receding into haze.
    case valleyFields
    /// cosmos flowers at dusk, fireflies coming out.
    case duskMeadow
}

/// renders one animated pixel scene. static layers are painted once; clouds, grass,
/// flowers, seeds and butterflies move every frame.
final class MeadowScene {
    let kind: SceneKind
    let width: Int
    let height: Int

    /// 1 is a breeze; scanning raises it so the meadow visibly works.
    var wind: Double = 1

    private var sky: PixelBuffer
    private var back: PixelBuffer
    private var front: PixelBuffer
    private var clouds: [Cloud] = []
    private var blades: [Blade] = []
    private var flowers: [Flower] = []
    private var motes: [Mote] = []
    private var flyers: [Flyer] = []
    private var ripples: [Ripple] = []
    private var bursts: [Burst] = []
    private var waterTop: Int?
    private var edgeMask: [Int] = []
    private var palette: Palette

    init(kind: SceneKind, width: Int, height: Int, seed: UInt64 = 11) {
        self.kind = kind
        self.width = max(width, 32)
        self.height = max(height, 24)
        palette = Palette.for(kind)
        sky = PixelBuffer(width: self.width, height: self.height)
        back = PixelBuffer(width: self.width, height: self.height)
        front = PixelBuffer(width: self.width, height: self.height)
        var rand = Rand(seed &+ UInt64(kind.rawValue) &* 7919)
        build(&rand)
        edgeMask = Self.mask(width: self.width, height: self.height, depth: 5)
    }

    // MARK: building

    private func build(_ rand: inout Rand) {
        let w = Double(width)
        let h = Double(height)
        switch kind {
        case .dandelionHill:
            let horizon = Int(h * 0.62)
            paintSky(horizon: horizon, sunAt: (0.82, 0.18))
            clouds = makeClouds(&rand, count: 4, yRange: (0.1, 0.34), size: (7, 11), towering: false)
            hillLayer(&rand, base: h * 0.52, amps: (5, 2.5, 1), freqs: (0.012, 0.031, 0.09), colors: palette.far, haze: 0.45, rim: true)
            let ground = hillLayer(&rand, base: h * 0.66, amps: (7, 3, 1), freqs: (0.008, 0.023, 0.07), colors: palette.near, haze: 0, rim: true)
            meadow(&rand, ground: ground, bladeDensity: 2.4, flowerDensity: 0.16, kinds: [.clock, .clock, .buttercup, .clover])
            motes = makeMotes(&rand, count: Int(w / 6), kind: .seed)
            flyers = makeFlyers(&rand, count: 2, kind: .butterfly)
        case .summerRidge:
            let horizon = Int(h * 0.7)
            paintSky(horizon: horizon, sunAt: (0.15, 0.12))
            clouds = makeClouds(&rand, count: 3, yRange: (0.05, 0.4), size: (9, 15), towering: true)
            hillLayer(&rand, base: h * 0.6, amps: (3, 2, 1), freqs: (0.01, 0.03, 0.08), colors: palette.far, haze: 0.55, rim: false)
            let ground = hillLayer(&rand, base: h * 0.62, amps: (9, 4, 1.2), freqs: (0.006, 0.019, 0.06), colors: palette.near, haze: 0, rim: true)
            tree(at: Int(w * 0.68), ground: ground, size: h * 0.42, &rand)
            meadow(&rand, ground: ground, bladeDensity: 3.0, flowerDensity: 0.05, kinds: [.daisy, .buttercup])
            motes = makeMotes(&rand, count: Int(w / 14), kind: .petal)
            flyers = makeFlyers(&rand, count: 3, kind: .bird)
        case .stillPond:
            let horizon = Int(h * 0.5)
            waterTop = horizon
            paintSky(horizon: horizon, sunAt: (0.7, 0.1))
            clouds = makeClouds(&rand, count: 5, yRange: (0.06, 0.32), size: (5, 10), towering: false)
            treeline(&rand, top: Double(horizon) - h * 0.14, bottom: horizon)
            lilyPads(&rand, top: horizon + 3)
            reeds(&rand)
            flyers = makeFlyers(&rand, count: 2, kind: .dragonfly)
            ripples = (0..<4).map { index in
                Ripple(x: rand.range(0.1, 0.9) * w, y: Double(horizon) + rand.range(0.25, 0.85) * (h - Double(horizon)),
                       period: rand.range(4.5, 7), phase: Double(index) * 1.7)
            }
        case .valleyFields:
            let horizon = Int(h * 0.42)
            paintSky(horizon: horizon, sunAt: (0.5, 0.05))
            clouds = makeClouds(&rand, count: 5, yRange: (0.05, 0.3), size: (4, 8), towering: false)
            let layers = 4
            var ground: [Int] = []
            for index in 0..<layers {
                let t = Double(index) / Double(layers - 1)
                let base = h * (0.38 + 0.18 * t)
                let colors = index == layers - 1 ? palette.near : palette.far
                ground = hillLayer(&rand, base: base, amps: (4 + 4 * t, 2, 1), freqs: (0.01 + 0.004 * t, 0.027, 0.08),
                                   colors: colors, haze: index == 0 ? 0.5 : (index == 1 ? 0.22 : 0), rim: true)
                if index > 0, index < layers - 1 { fields(&rand, top: ground, depth: 0.7 + t) }
            }
            meadow(&rand, ground: ground, bladeDensity: 1.6, flowerDensity: 0.06, kinds: [.clover, .daisy])
            flyers = makeFlyers(&rand, count: 4, kind: .bird)
        case .duskMeadow:
            let horizon = Int(h * 0.66)
            paintSky(horizon: horizon, sunAt: (0.28, 0.6))
            clouds = makeClouds(&rand, count: 4, yRange: (0.1, 0.38), size: (5, 10), towering: false)
            hillLayer(&rand, base: h * 0.6, amps: (4, 2, 1), freqs: (0.011, 0.03, 0.09), colors: palette.far, haze: 0, rim: true)
            let ground = hillLayer(&rand, base: h * 0.7, amps: (6, 2.5, 1), freqs: (0.009, 0.025, 0.07), colors: palette.near, haze: 0, rim: true)
            meadow(&rand, ground: ground, bladeDensity: 2.2, flowerDensity: 0.2, kinds: [.cosmos, .cosmos, .cosmosWhite, .clover])
            motes = makeMotes(&rand, count: Int(w / 9), kind: .firefly)
        }
    }

    private func paintSky(horizon: Int, sunAt: (Double, Double)) {
        let sunX = sunAt.0 * Double(width)
        let sunY = sunAt.1 * Double(height)
        for y in 0..<height {
            let v = Double(min(y, horizon)) / Double(max(horizon, 1)) * Double(palette.sky.count - 1)
            for x in 0..<width {
                var color = Bayer.ramp(palette.sky, v, x, y)
                let dx = (Double(x) - sunX) / 1.6
                let dy = Double(y) - sunY
                let d = (dx * dx + dy * dy).squareRoot()
                let glow = max(0, 1 - d / (Double(height) * 0.3))
                if glow > 0 { color = Bayer.pick(color, palette.glow, pow(glow, 2.2) * 0.75, x, y) }
                if d < 2.2 { color = palette.sun }
                sky.set(x, y, color)
            }
        }
    }

    @discardableResult
    private func hillLayer(
        _ rand: inout Rand, base: Double, amps: (Double, Double, Double), freqs: (Double, Double, Double),
        colors: [Pixel], haze: Double, rim: Bool
    ) -> [Int] {
        let p1 = rand.range(0, 6.28), p2 = rand.range(0, 6.28), p3 = rand.range(0, 6.28)
        var tops: [Int] = []
        for x in 0..<width {
            let xd = Double(x)
            let top = base - amps.0 * sin(xd * freqs.0 + p1) - amps.1 * sin(xd * freqs.1 + p2) - amps.2 * sin(xd * freqs.2 + p3)
            let topY = Int(top.rounded())
            tops.append(topY)
            for y in max(topY, 0)..<height {
                let depth = Double(y - topY)
                var color = Bayer.ramp(colors, min(depth / 10, Double(colors.count - 1)), x, y)
                if rim, depth < 1 { color = palette.rim }
                if haze > 0 { color = Bayer.pick(color, palette.haze, haze, x, y) }
                back.set(x, y, color)
            }
        }
        return tops
    }

    private func treeline(_ rand: inout Rand, top: Double, bottom: Int) {
        var x = -4.0
        while x < Double(width) + 4 {
            let r = rand.range(3, 7)
            let cy = top + rand.range(0, Double(bottom) - top) * 0.5
            blob(cx: x, cy: cy, r: r, light: palette.far[0], mid: palette.far[1], dark: palette.far[2], into: &back)
            x += r * rand.range(0.8, 1.4)
        }
        for x in 0..<width {
            for y in Int(top)..<bottom where back.packed(x, y) == 0 && y > Int(top) + 4 {
                back.set(x, y, palette.far[2])
            }
        }
    }

    private func blob(cx: Double, cy: Double, r: Double, light: Pixel, mid: Pixel, dark: Pixel, into buffer: inout PixelBuffer) {
        let ri = Int(r.rounded(.up))
        for yy in -ri...ri {
            for xx in -ri...ri {
                let dx = Double(xx), dy = Double(yy) * 1.15
                guard dx * dx + dy * dy <= r * r else { continue }
                let x = Int(cx) + xx, y = Int(cy) + yy
                // light from the upper left.
                let shade = (dx * -0.6 + dy * -0.8) / r
                let color = shade > 0.35 ? light : (shade > -0.35 ? mid : dark)
                buffer.set(x, y, Bayer.pick(color, shade > 0 ? light : dark, abs(shade) * 0.35, x, y))
            }
        }
    }

    private func tree(at x: Int, ground: [Int], size: Double, _ rand: inout Rand) {
        let baseY = ground[min(max(x, 0), width - 1)]
        let trunkTop = baseY - Int(size * 0.45)
        for y in trunkTop...baseY {
            for dx in -2...1 { back.set(x + dx, y, dx < 0 ? palette.bark[0] : palette.bark[1]) }
        }
        let crown = Double(trunkTop) - size * 0.2
        for _ in 0..<18 {
            let cx = Double(x) + rand.range(-size * 0.55, size * 0.55)
            let cy = crown + rand.range(-size * 0.32, size * 0.25)
            blob(cx: cx, cy: cy, r: rand.range(size * 0.16, size * 0.28),
                 light: palette.leaf[0], mid: palette.leaf[1], dark: palette.leaf[2], into: &back)
        }
    }

    private func fields(_ rand: inout Rand, top: [Int], depth: Double) {
        let bands = palette.fields
        var edges: [Int] = []
        var x = 0
        while x < width {
            edges.append(x)
            x += rand.int(Int(18 * depth), Int(40 * depth))
        }
        for (index, start) in edges.enumerated() {
            let end = index + 1 < edges.count ? edges[index + 1] : width
            let color = bands[rand.int(0, bands.count - 1)]
            for xx in start..<end {
                let t = top[min(xx, width - 1)]
                for y in (t + 2)..<min(t + Int(6 * depth), height) {
                    back.set(xx, y, Bayer.pick(color, palette.near[0], 0.12, xx, y))
                }
            }
            // a hedgerow of dots between fields.
            let hedge = top[min(start, width - 1)]
            for y in stride(from: hedge + 1, to: min(hedge + Int(6 * depth), height), by: 2) {
                back.set(start, y, palette.near[2])
            }
        }
    }

    private func lilyPads(_ rand: inout Rand, top: Int) {
        for _ in 0..<Int(Double(width) / 14) {
            let cx = rand.range(4, Double(width) - 4)
            let cy = rand.range(Double(top) + 4, Double(height) - 2)
            let nearness = (cy - Double(top)) / Double(max(height - top, 1))
            let rx = 2 + nearness * 5, ry = rx * 0.38
            for yy in -Int(ry) - 1...Int(ry) + 1 {
                for xx in -Int(rx) - 1...Int(rx) + 1 {
                    let fx = Double(xx) / rx, fy = Double(yy) / max(ry, 0.8)
                    guard fx * fx + fy * fy <= 1 else { continue }
                    // the notch.
                    if xx > 0, abs(yy) <= 0, fx > 0.2 { continue }
                    let color = yy < 0 ? palette.leaf[0] : palette.leaf[1]
                    front.set(Int(cx) + xx, Int(cy) + yy, color)
                }
            }
            if rand.chance(0.3) {
                front.set(Int(cx) - 1, Int(cy - ry) - 1, palette.blossom[0])
                front.set(Int(cx), Int(cy - ry) - 2, palette.blossom[1])
                front.set(Int(cx) + 1, Int(cy - ry) - 1, palette.blossom[0])
                front.set(Int(cx), Int(cy - ry) - 1, palette.blossom[2])
            }
        }
    }

    private func reeds(_ rand: inout Rand) {
        for side in [0.0, 1.0] {
            let count = Int(Double(width) * 0.12)
            for _ in 0..<count {
                let spread = rand.range(0, Double(width) * 0.16)
                let x = side == 0 ? spread : Double(width) - spread
                let root = Double(height) + 1
                blades.append(Blade(x: x, root: root, length: rand.range(Double(height) * 0.2, Double(height) * 0.55),
                                    tone: rand.int(0, 2), phase: rand.range(0, 6.28), stiffness: 0.6))
            }
        }
    }

    private func meadow(_ rand: inout Rand, ground: [Int], bladeDensity: Double, flowerDensity: Double, kinds: [FlowerKind]) {
        for x in 0..<width {
            let top = Double(ground[x])
            let span = Double(height) - top
            guard span > 0 else { continue }
            for _ in 0..<Int(bladeDensity.rounded(.down)) + (rand.chance(bladeDensity.truncatingRemainder(dividingBy: 1)) ? 1 : 0) {
                let depth = pow(rand.unit(), 0.7)
                let root = top + 1 + depth * span
                let length = 2 + depth * span * 0.5 + rand.range(0, 3)
                blades.append(Blade(x: Double(x) + rand.range(-0.4, 0.4), root: root, length: length,
                                    tone: depth > 0.6 ? 0 : (depth > 0.25 ? 1 : 2), phase: rand.range(0, 6.28), stiffness: 1))
            }
            if rand.chance(flowerDensity) {
                let depth = pow(rand.unit(), 0.8)
                let root = top + 2 + depth * span
                flowers.append(Flower(x: Double(x), root: root, stem: 2 + depth * span * 0.45 + rand.range(0, 4),
                                      kind: kinds[rand.int(0, kinds.count - 1)], big: depth > 0.55, phase: rand.range(0, 6.28)))
            }
        }
        blades.sort { $0.root < $1.root }
        flowers.sort { $0.root < $1.root }
    }

    private func makeClouds(_ rand: inout Rand, count: Int, yRange: (Double, Double), size: (Double, Double), towering: Bool) -> [Cloud] {
        (0..<count).map { _ in
            let r = rand.range(size.0, size.1)
            var puffs: [(Double, Double, Double)] = []
            let spread = towering ? r * 1.4 : r * 2.6
            for _ in 0..<(towering ? 9 : 6) {
                let dx = rand.range(-spread, spread)
                let lift = towering ? rand.range(0, r * 2.2) : rand.range(0, r * 0.6)
                puffs.append((dx, -lift, rand.range(r * 0.5, r) * (1 - abs(dx) / (spread * 2))))
            }
            return Cloud(x: rand.range(0, Double(width)), y: rand.range(yRange.0, yRange.1) * Double(height) + r,
                         puffs: puffs, speed: rand.range(0.6, 1.6) * (towering ? 0.4 : 1), base: r * 0.35)
        }
    }

    private func makeMotes(_ rand: inout Rand, count: Int, kind: MoteKind) -> [Mote] {
        (0..<count).map { _ in
            Mote(x: rand.range(0, Double(width)), y: rand.range(0, Double(height)),
                 vx: kind == .firefly ? rand.range(-0.6, 0.6) : rand.range(3, 7),
                 vy: kind == .firefly ? rand.range(-0.4, 0.4) : rand.range(-1.6, -0.3),
                 phase: rand.range(0, 6.28), kind: kind)
        }
    }

    private func makeFlyers(_ rand: inout Rand, count: Int, kind: FlyerKind) -> [Flyer] {
        (0..<count).map { _ in
            Flyer(cx: rand.range(0.2, 0.8) * Double(width),
                  cy: (kind == .bird ? rand.range(0.12, 0.3) : rand.range(0.45, 0.7)) * Double(height),
                  ax: rand.range(0.12, 0.3) * Double(width), ay: rand.range(0.05, 0.12) * Double(height),
                  wx: rand.range(0.07, 0.16), wy: rand.range(0.2, 0.4), phase: rand.range(0, 6.28), kind: kind,
                  color: kind == .butterfly ? palette.butterfly[rand.int(0, palette.butterfly.count - 1)] : palette.bird)
        }
    }

    static func mask(width: Int, height: Int, depth: Int) -> [Int] {
        var probe = PixelBuffer(width: width, height: height, fill: 1)
        probe.raggedEdges(depth: depth)
        return probe.pixels.indices.filter { probe.pixels[$0] == 0 }
    }

    // MARK: interaction

    /// scatters petals or seeds from a point, in scene pixels.
    func burst(at point: (Double, Double), time: Double) {
        var rand = Rand(UInt64(time * 1000))
        for _ in 0..<26 {
            let angle = rand.range(0, 6.28)
            let speed = rand.range(6, 22)
            bursts.append(Burst(x: point.0, y: point.1, vx: cos(angle) * speed, vy: sin(angle) * speed - 10,
                                born: time, color: palette.burst[rand.int(0, palette.burst.count - 1)]))
        }
    }

    // MARK: drawing a frame

    func frame(at t: Double) -> PixelBuffer {
        var out = sky
        for cloud in clouds { draw(cloud, t, &out) }
        overlay(back, onto: &out)
        if let waterTop { reflect(from: waterTop, t, &out) }
        overlay(front, onto: &out)
        for ripple in ripples { draw(ripple, t, &out) }
        let gust = wind * (1 + 0.35 * sin(t * 0.37))
        for blade in blades { draw(blade, t, gust, &out) }
        for flower in flowers { draw(flower, t, gust, &out) }
        for mote in motes { draw(mote, t, gust, &out) }
        for flyer in flyers { draw(flyer, t, &out) }
        drawBursts(t, &out)
        for index in edgeMask { out.pixels[index] = 0 }
        return out
    }

    private func overlay(_ layer: PixelBuffer, onto out: inout PixelBuffer) {
        for index in layer.pixels.indices where layer.pixels[index] != 0 {
            out.pixels[index] = layer.pixels[index]
        }
    }

    private func draw(_ cloud: Cloud, _ t: Double, _ out: inout PixelBuffer) {
        let span = Double(width) + 80
        let cx = (cloud.x + t * cloud.speed * wind).truncatingRemainder(dividingBy: span) - 40
        var minX = Int.max, maxX = Int.min, minY = Int.max
        for puff in cloud.puffs {
            minX = min(minX, Int(cx + puff.0 - puff.2) - 1)
            maxX = max(maxX, Int(cx + puff.0 + puff.2) + 1)
            minY = min(minY, Int(cloud.y + puff.1 - puff.2) - 1)
        }
        let baseY = cloud.y + cloud.base
        let top = Double(minY)
        for y in max(minY, 0)...max(min(Int(baseY), height - 1), 0) {
            for x in max(minX, 0)...max(min(maxX, width - 1), 0) {
                var inside = false
                for puff in cloud.puffs {
                    let dx = Double(x) - (cx + puff.0)
                    let dy = (Double(y) - (cloud.y + puff.1)) * 1.1
                    if dx * dx + dy * dy <= puff.2 * puff.2 { inside = true; break }
                }
                guard inside else { continue }
                let height01 = (baseY - Double(y)) / max(baseY - top, 1)
                let color = Bayer.ramp([palette.cloudShade, palette.cloudMid, palette.cloudLight], height01 * 2.4, x, y)
                out.set(x, y, color)
            }
        }
    }

    private func reflect(from waterTop: Int, _ t: Double, _ out: inout PixelBuffer) {
        for y in waterTop..<height {
            let depth = Double(y - waterTop)
            let source = waterTop - 1 - Int(depth * 0.9)
            let wobble = Int((sin(Double(y) * 0.8 + t * 1.8) * (0.6 + depth * 0.06)).rounded())
            for x in 0..<width {
                let sample = out.packed(min(max(x + wobble, 0), width - 1), max(source, 0))
                let base = Pixel(r: UInt8(sample & 0xFF), g: UInt8((sample >> 8) & 0xFF), b: UInt8((sample >> 16) & 0xFF))
                var color = base.mixed(palette.water, 0.28 + depth / Double(height) * 0.5)
                if (y + Int(t * 2)) % 5 == 0, hash01(x / 3, y, 3) > 0.55 { color = color.mixed(palette.cloudLight, 0.35) }
                out.set(x, y, color)
            }
        }
    }

    private func draw(_ ripple: Ripple, _ t: Double, _ out: inout PixelBuffer) {
        let age = (t + ripple.phase).truncatingRemainder(dividingBy: ripple.period)
        let r = age * 3.2
        guard r > 0.5, age < ripple.period * 0.7 else { return }
        let fade = 1 - age / (ripple.period * 0.7)
        let steps = max(Int(r * 7), 12)
        for step in 0..<steps {
            let angle = Double(step) / Double(steps) * 6.283
            let x = Int((ripple.x + cos(angle) * r).rounded())
            let y = Int((ripple.y + sin(angle) * r * 0.32).rounded())
            if fade > Bayer.threshold(x, y) * 0.9 { out.set(x, y, palette.cloudLight) }
        }
    }

    private func sway(_ x: Double, _ t: Double, _ gust: Double) -> Double {
        gust * (1.1 * sin(t * 1.5 + x * 0.045) + 0.5 * sin(t * 2.6 + x * 0.13))
    }

    private func draw(_ blade: Blade, _ t: Double, _ gust: Double, _ out: inout PixelBuffer) {
        let bend = sway(blade.x, t, gust) * blade.stiffness + 0.35 * sin(t * 3 + blade.phase)
        let color = palette.grass[blade.tone]
        let steps = Int(blade.length)
        guard steps > 0 else { return }
        for k in 0..<steps {
            let f = Double(k) / Double(steps)
            let x = Int((blade.x + bend * f * f * blade.length / 9).rounded())
            let shade = k == steps - 1 ? palette.grass[min(blade.tone + 1, palette.grass.count - 1)] : color
            out.set(x, Int(blade.root) - k, shade)
        }
    }

    private func draw(_ flower: Flower, _ t: Double, _ gust: Double, _ out: inout PixelBuffer) {
        let bend = sway(flower.x, t, gust) * 0.8 + 0.3 * sin(t * 2.2 + flower.phase)
        let steps = Int(flower.stem)
        var tipX = Int(flower.x)
        for k in 0..<max(steps, 1) {
            let f = Double(k) / Double(max(steps, 1))
            tipX = Int((flower.x + bend * f * f * flower.stem / 10).rounded())
            out.set(tipX, Int(flower.root) - k, palette.grass[1])
        }
        let tipY = Int(flower.root) - steps
        let sprite = flower.kind.sprite(big: flower.big)
        let colors = palette.colors(for: flower.kind)
        let ox = tipX - sprite[0].count / 2
        let oy = tipY - sprite.count / 2
        for (row, line) in sprite.enumerated() {
            for (column, char) in line.enumerated() {
                guard let index = "abc".firstIndex(of: char).map({ "abc".distance(from: "abc".startIndex, to: $0) }) else { continue }
                out.set(ox + column, oy + row, colors[index])
            }
        }
    }

    private func draw(_ mote: Mote, _ t: Double, _ gust: Double, _ out: inout PixelBuffer) {
        let w = Double(width) + 8, h = Double(height) + 8
        switch mote.kind {
        case .firefly:
            let x = mote.x + sin(t * 0.5 + mote.phase) * 6 + mote.vx * t
            let y = mote.y * 0.8 + Double(height) * 0.2 + cos(t * 0.7 + mote.phase) * 3 + mote.vy * t
            let glow = 0.5 + 0.5 * sin(t * 2.4 + mote.phase * 3)
            guard glow > 0.35 else { return }
            let px = Int(wrap(x, w)) - 4, py = Int(wrap(y, h)) - 4
            out.set(px, py, palette.burst[0])
            if glow > 0.8 {
                out.set(px + 1, py, palette.glow)
                out.set(px - 1, py, palette.glow)
            }
        case .seed, .petal:
            let x = wrap(mote.x + mote.vx * t * gust, w) - 4
            let y = wrap(mote.y + mote.vy * t + sin(t * 1.3 + mote.phase) * 2.5, h) - 4
            let color = mote.kind == .seed ? palette.cloudLight : palette.burst[Int(mote.phase * 10) % palette.burst.count]
            out.set(Int(x), Int(y), color)
            if mote.kind == .seed, Int(mote.phase * 100) % 3 == 0 { out.set(Int(x) - 1, Int(y), palette.cloudMid) }
        }
    }

    private func draw(_ flyer: Flyer, _ t: Double, _ out: inout PixelBuffer) {
        let x = Int(flyer.cx + flyer.ax * sin(t * flyer.wx + flyer.phase))
        let y = Int(flyer.cy + flyer.ay * sin(t * flyer.wy + flyer.phase * 2))
        let flap = Int(t * (flyer.kind == .bird ? 5 : 9) + flyer.phase) % 2 == 0
        switch flyer.kind {
        case .butterfly, .dragonfly:
            let body = flyer.kind == .dragonfly ? palette.bird : palette.grass[0]
            out.set(x, y, body)
            if flap {
                out.set(x - 1, y - 1, flyer.color); out.set(x + 1, y - 1, flyer.color)
                out.set(x - 1, y, flyer.color); out.set(x + 1, y, flyer.color)
            } else {
                out.set(x, y - 1, flyer.color)
            }
            if flyer.kind == .dragonfly { out.set(x + 1, y + 1, body); out.set(x + 2, y + 1, body) }
        case .bird:
            if flap {
                out.set(x - 1, y - 1, flyer.color); out.set(x, y, flyer.color); out.set(x + 1, y - 1, flyer.color)
            } else {
                out.set(x - 1, y, flyer.color); out.set(x, y, flyer.color); out.set(x + 1, y, flyer.color)
            }
        }
    }

    private func drawBursts(_ t: Double, _ out: inout PixelBuffer) {
        bursts.removeAll { t - $0.born > 2.2 }
        for burst in bursts {
            let age = t - burst.born
            let x = burst.x + burst.vx * age
            let y = burst.y + burst.vy * age + 9 * age * age
            if age < 1.6 || Bayer.threshold(Int(x), Int(y)) > (age - 1.6) / 0.6 {
                out.set(Int(x), Int(y), burst.color)
            }
        }
    }

    private func wrap(_ value: Double, _ span: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: span)
        return r < 0 ? r + span : r
    }
}

// MARK: elements

private struct Cloud {
    var x: Double
    var y: Double
    var puffs: [(Double, Double, Double)]
    var speed: Double
    var base: Double
}

private struct Blade {
    var x: Double
    var root: Double
    var length: Double
    var tone: Int
    var phase: Double
    var stiffness: Double
}

enum FlowerKind {
    case clock, buttercup, clover, daisy, cosmos, cosmosWhite

    /// a, b, c index into the flower's three colours; anything else is empty.
    func sprite(big: Bool) -> [[Character]] {
        let rows: [String]
        switch (self, big) {
        case (.clock, false): rows = [".a.", "aba", ".a."]
        case (.clock, true): rows = [".aba.", "abaab", "baaba", "abaab", ".aba."]
        case (.buttercup, false): rows = ["a.a", "aba"]
        case (.buttercup, true): rows = ["a...a", "aa.aa", "abcba", ".aaa."]
        case (.clover, false): rows = [".b.", "aba", ".a."]
        case (.clover, true): rows = [".bb.", "baab", "aaaa", ".aa."]
        case (.daisy, false): rows = [".a.", "aca", ".a."]
        case (.daisy, true): rows = [".a.a.", "aaaaa", ".aca.", "aaaaa", ".a.a."]
        case (.cosmos, false), (.cosmosWhite, false): rows = ["a.a", ".c.", "a.a"]
        case (.cosmos, true), (.cosmosWhite, true): rows = [".a.a.", "abbba", ".bcb.", "abbba", ".a.a."]
        }
        return rows.map(Array.init)
    }
}

private struct Flower {
    var x: Double
    var root: Double
    var stem: Double
    var kind: FlowerKind
    var big: Bool
    var phase: Double
}

private enum MoteKind { case seed, petal, firefly }

private struct Mote {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var phase: Double
    var kind: MoteKind
}

private enum FlyerKind { case butterfly, bird, dragonfly }

private struct Flyer {
    var cx: Double
    var cy: Double
    var ax: Double
    var ay: Double
    var wx: Double
    var wy: Double
    var phase: Double
    var kind: FlyerKind
    var color: Pixel
}

private struct Ripple {
    var x: Double
    var y: Double
    var period: Double
    var phase: Double
}

private struct Burst {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var born: Double
    var color: Pixel
}

// MARK: palettes

struct Palette {
    var sky: [Pixel]
    var glow: Pixel
    var sun: Pixel
    var haze: Pixel
    var cloudLight: Pixel
    var cloudMid: Pixel
    var cloudShade: Pixel
    var far: [Pixel]
    var near: [Pixel]
    var rim: Pixel
    var grass: [Pixel]
    var leaf: [Pixel]
    var bark: [Pixel]
    var fields: [Pixel]
    var water: Pixel
    var blossom: [Pixel]
    var butterfly: [Pixel]
    var bird: Pixel
    var burst: [Pixel]
    var flowers: [FlowerKind: [Pixel]]

    func colors(for kind: FlowerKind) -> [Pixel] {
        flowers[kind] ?? [Pixel(0xFFFFFF), Pixel(0xFFE48A), Pixel(0xF2B33D)]
    }

    static func `for`(_ kind: SceneKind) -> Palette {
        let day = Palette(
            sky: [Pixel(0x3A8EDB), Pixel(0x58A7EA), Pixel(0x7DC0F2), Pixel(0xA9D8F7), Pixel(0xD3EDFB)],
            glow: Pixel(0xF4FBFF), sun: Pixel(0xFFFFFF), haze: Pixel(0xB9DDF2),
            cloudLight: Pixel(0xFFFFFF), cloudMid: Pixel(0xEEF6FD), cloudShade: Pixel(0xC4DBEE),
            far: [Pixel(0x8CC98A), Pixel(0x6DB37A), Pixel(0x4F9468)],
            near: [Pixel(0x7CC45A), Pixel(0x5AAE4C), Pixel(0x3F8F43), Pixel(0x2E7038)],
            rim: Pixel(0xB6E37C),
            grass: [Pixel(0x2C6E3A), Pixel(0x3F9446), Pixel(0x6CBF55), Pixel(0x9FDA6E)],
            leaf: [Pixel(0x8FD06B), Pixel(0x4E9E4A), Pixel(0x2D6B3B)],
            bark: [Pixel(0x5A4636), Pixel(0x7A604A)],
            fields: [Pixel(0x9ACD5E), Pixel(0xC9DD72), Pixel(0x74B95A), Pixel(0xE2D27A)],
            water: Pixel(0x2F79B8),
            blossom: [Pixel(0xF7A8C4), Pixel(0xFFD6E5), Pixel(0xF2C14E)],
            butterfly: [Pixel(0xFFFFFF), Pixel(0xFFE07A), Pixel(0xA8D8FF)],
            bird: Pixel(0x2E3A46),
            burst: [Pixel(0xFFFFFF), Pixel(0xFFD6E5), Pixel(0xFFE48A)],
            flowers: [
                .clock: [Pixel(0xFFFFFF), Pixel(0xDCE9F2), Pixel(0xC9D7E0)],
                .buttercup: [Pixel(0xFFCF3A), Pixel(0xFFE88A), Pixel(0xE09A1F)],
                .clover: [Pixel(0xE873A4), Pixel(0xF7B3CE), Pixel(0xB84C7E)],
                .daisy: [Pixel(0xFFFFFF), Pixel(0xF3F3F3), Pixel(0xF2B33D)],
                .cosmos: [Pixel(0xEE6FA6), Pixel(0xF9A9CB), Pixel(0xF2C14E)],
                .cosmosWhite: [Pixel(0xFFFFFF), Pixel(0xF6E6EE), Pixel(0xF2C14E)],
            ]
        )
        switch kind {
        case .dandelionHill, .valleyFields:
            return day
        case .summerRidge:
            var p = day
            p.sky = [Pixel(0x1F78D1), Pixel(0x3B92E4), Pixel(0x63AEEF), Pixel(0x98CEF6), Pixel(0xCBE9FB)]
            p.rim = Pixel(0xC6EC86)
            return p
        case .stillPond:
            var p = day
            p.far = [Pixel(0x5FA56B), Pixel(0x3F8556), Pixel(0x2B6447)]
            p.leaf = [Pixel(0x7CC46A), Pixel(0x4C9A52), Pixel(0x2D6B3B)]
            p.grass = [Pixel(0x2B6A45), Pixel(0x3E8A4C), Pixel(0x5FAF57), Pixel(0x8BCB6A)]
            return p
        case .duskMeadow:
            var p = day
            p.sky = [Pixel(0x3B3F8F), Pixel(0x6B4F9E), Pixel(0xB0629C), Pixel(0xE88A84), Pixel(0xF8C07A), Pixel(0xFCE3A6)]
            p.glow = Pixel(0xFFE7B0)
            p.sun = Pixel(0xFFF3D1)
            p.haze = Pixel(0xC98CA0)
            p.cloudLight = Pixel(0xFFD9C2)
            p.cloudMid = Pixel(0xF2A99C)
            p.cloudShade = Pixel(0xB57794)
            p.far = [Pixel(0x6E5E93), Pixel(0x58507F), Pixel(0x45436B)]
            p.near = [Pixel(0x3E6A5E), Pixel(0x335A52), Pixel(0x294A45), Pixel(0x203B39)]
            p.rim = Pixel(0xD98C8A)
            p.grass = [Pixel(0x1E3D38), Pixel(0x2C5549), Pixel(0x3E6E57), Pixel(0x5E8C62)]
            p.burst = [Pixel(0xFFF2A0), Pixel(0xFFD6E5), Pixel(0xFFFFFF)]
            p.bird = Pixel(0x2B2440)
            return p
        }
    }
}
