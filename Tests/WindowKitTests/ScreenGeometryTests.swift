import CoreGraphics
import Testing
@testable import WindowKit

@Suite struct ScreenGeometryTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// To the right of the laptop, top edges aligned.
    let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    let window = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func parksPastTheBottomRightCorner() {
        let origin = ScreenGeometry.parkingOrigin(for: window, in: [laptop])
        #expect(origin == CGPoint(x: 1511, y: 981))
    }

    @Test func parksBottomLeftWhenAScreenIsToTheRight() {
        let origin = ScreenGeometry.parkingOrigin(for: window, in: [laptop, external])
        #expect(origin == CGPoint(x: -799, y: 981))
    }

    @Test func windowsOnTheExternalScreenParkThere() {
        let onExternal = CGRect(x: 2000, y: 200, width: 1000, height: 800)
        #expect(ScreenGeometry.parkingOrigin(for: onExternal, in: [laptop, external]) == CGPoint(x: 4071, y: 1439))
    }

    @Test func parkedWindowsAreMostlyOffscreenWhereverMacOSClampedThem() {
        // Sent to (1511, 981), clamped by macOS to keep part of the title bar above the Dock.
        #expect(ScreenGeometry.isMostlyOffscreen(CGRect(x: 1511, y: 930, width: 800, height: 600), in: [laptop]))
        #expect(ScreenGeometry.isMostlyOffscreen(CGRect(x: -799, y: 981, width: 800, height: 600), in: [laptop, external]))
        #expect(!ScreenGeometry.isMostlyOffscreen(window, in: [laptop, external]))
        // Half off the edge is still usable.
        #expect(!ScreenGeometry.isMostlyOffscreen(CGRect(x: 1112, y: 100, width: 800, height: 600), in: [laptop]))
        // Spanning two screens counts both.
        #expect(!ScreenGeometry.isMostlyOffscreen(CGRect(x: 1300, y: 100, width: 800, height: 600), in: [laptop, external]))
    }

    @Test func hiddenFramesComeBackCentered() {
        let stranded = CGRect(x: 3359, y: 1838, width: 1811, height: 1334)
        let big = CGRect(x: 0, y: 0, width: 3360, height: 1890)
        let rescued = ScreenGeometry.onScreen(stranded, in: [big])
        #expect(rescued == CGRect(x: 774.5, y: 278, width: 1811, height: 1334))
        #expect(ScreenGeometry.onScreen(window, in: [laptop]) == window)
        // Too big for the screen: shrunk to 90%.
        let huge = ScreenGeometry.onScreen(CGRect(x: 5000, y: 5000, width: 4000, height: 3000), in: [laptop])
        #expect(huge.width == 1512 * 0.9 && huge.height == 982 * 0.9)
    }

    @Test func screenForAWindowHalfOffScreen() {
        let straddling = CGRect(x: 1400, y: 100, width: 400, height: 300)
        #expect(ScreenGeometry.screen(for: straddling, in: [laptop, external]) == external)
    }

    @Test func scratchpadWindowsFitInsetAndCentered() {
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
        // Too big: scaled down to fit 80%, proportions kept, centered.
        let big = ScreenGeometry.scratchpadFrame(for: CGSize(width: 1000, height: 500), in: visible)
        #expect(big.size == CGSize(width: 800, height: 400))
        #expect(big.midX == visible.midX && big.midY == visible.midY)
        // Small enough: its own size, centered.
        let small = ScreenGeometry.scratchpadFrame(for: CGSize(width: 400, height: 300), in: visible)
        #expect(small == CGRect(x: 300, y: 275, width: 400, height: 300))
    }
}
