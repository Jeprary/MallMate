import Foundation

/// Project trial parameters, not Apple standards or a field accuracy guarantee.
/// Camera height is relative to the saved endpoint floor; no GPS or frame history is used.
struct RouteArrivalPolicy {
    static let horizontalRadius: Float = 1.5
    static let dwellDuration: TimeInterval = 2
    static let cameraHeight: ClosedRange<Float> = 0.4...2.4
    static let maximumFrameGap: TimeInterval = 0.75

    private(set) var hasArrived = false
    private var dwellStart: TimeInterval?
    private var previousTimestamp: TimeInterval?

    /// Revokes incomplete dwell immediately on tracking loss, pause or a new AR run.
    /// Arrival is terminal for the route session and survives these events.
    mutating func invalidatePending() {
        dwellStart = nil
        previousTimestamp = nil
    }

    mutating func reset() { self = Self() }

    @discardableResult
    mutating func observe(camera: SIMD3<Float>, target: SIMD3<Float>,
                          timestamp: TimeInterval, aligned: Bool) -> Bool {
        guard !hasArrived else { return true }
        guard aligned, timestamp.isFinite,
              camera.x.isFinite, camera.y.isFinite, camera.z.isFinite,
              target.x.isFinite, target.y.isFinite, target.z.isFinite else {
            invalidatePending()
            return false
        }
        if let previousTimestamp {
            guard timestamp > previousTimestamp else {
                invalidatePending()
                return false
            }
            if timestamp - previousTimestamp > Self.maximumFrameGap { invalidatePending() }
        }
        let offset = camera - target
        let horizontalDistance = hypot(offset.x, offset.z)
        guard horizontalDistance <= Self.horizontalRadius,
              Self.cameraHeight.contains(offset.y) else {
            invalidatePending()
            return false
        }
        previousTimestamp = timestamp
        if dwellStart == nil { dwellStart = timestamp }
        if let dwellStart, timestamp - dwellStart >= Self.dwellDuration { hasArrived = true }
        return hasArrived
    }
}
