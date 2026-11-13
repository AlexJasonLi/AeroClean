import CoreGraphics
import Testing
@testable import AeroCleanUI

struct SceneStressTests {
    /// every cloud crosses both edges in ten minutes of scene time; any bad range traps here.
    @Test(arguments: SceneKind.allCases)
    func rendersForTenMinutesAtManySizes(_ kind: SceneKind) {
        for (width, height) in [(32, 24), (48, 48), (120, 30), (400, 107), (640, 90)] {
            let scene = MeadowScene(kind: kind, width: width, height: height)
            scene.burst(at: (Double(width) / 2, Double(height) / 2), time: 1)
            var t = 0.0
            while t < 600 {
                let frame = scene.frame(at: t)
                #expect(frame.pixels.count == scene.width * scene.height)
                t += 1.7
            }
        }
    }

    @Test func pixelCornersSurviveTinyRects() {
        for size in [0.0, 1, 2.5, 5, 40] {
            _ = PixelCorners(radius: 12).path(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}
