import CoreGraphics
import Testing
@testable import WindowKit

@Suite struct DesktopTests {
    @Test func homeWhenMostOfItsWindowsAreOnScreen() {
        #expect(Desktop.isHome([1, 2, 3, 4], onScreen: [1, 2, 3, 4, 9]))
        #expect(Desktop.isHome([1, 2, 3, 4], onScreen: [1, 2]))
    }

    @Test func awayWhenOnlyAllDesktopWindowsShow() {
        // Window 1 is assigned to every desktop; the rest stayed behind.
        #expect(!Desktop.isHome([1, 2, 3, 4, 5], onScreen: [1, 7, 8]))
        #expect(!Desktop.isHome([1, 2, 3], onScreen: []))
    }

    @Test func withNothingKnownAnyDesktopIsHome() {
        #expect(Desktop.isHome([], onScreen: [4]))
    }
}
