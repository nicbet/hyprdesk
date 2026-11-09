import CoreGraphics

/// Hover selects only once the pointer has really moved since an overlay opened: views sliding
/// in under a resting pointer mustn't steal the selection from the keyboard's.
public struct PointerGate: Sendable {
    private var origin: CGPoint?
    private var armed = false

    /// How far the pointer must move, in points.
    public static let threshold: CGFloat = 4

    public init() {}

    /// The overlay opened with the pointer at `point`.
    public mutating func reset(at point: CGPoint) {
        origin = point
        armed = false
    }

    /// Whether hovering may select, with the pointer now at `point`. Stays true once it has.
    public mutating func allows(at point: CGPoint) -> Bool {
        if !armed, let origin, hypot(point.x - origin.x, point.y - origin.y) <= Self.threshold { return false }
        armed = true
        return true
    }
}
