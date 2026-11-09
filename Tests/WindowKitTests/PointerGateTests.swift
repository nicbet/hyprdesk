import CoreGraphics
import Testing
@testable import WindowKit

@Suite struct PointerGateTests {
    @Test func hoverWaitsForTheFirstRealMove() {
        var gate = PointerGate()
        gate.reset(at: CGPoint(x: 100, y: 100))
        let resting = gate.allows(at: CGPoint(x: 100, y: 100))
        let jitter = gate.allows(at: CGPoint(x: 102, y: 101))
        let moved = gate.allows(at: CGPoint(x: 110, y: 100))
        // Once moved, back at the start still counts.
        let back = gate.allows(at: CGPoint(x: 100, y: 100))
        #expect(!resting && !jitter && moved && back)
        gate.reset(at: .zero)
        let afterReset = gate.allows(at: CGPoint(x: 1, y: 1))
        #expect(!afterReset)
    }
}
