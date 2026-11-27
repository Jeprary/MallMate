/// A fresh normal frame with all saved anchors confirms that ARKit restored the map.
/// https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap
/// Tracking change callbacks can revoke readiness immediately; only a frame can grant it.
struct RouteTrackingGate {
    enum Signal { case limited, matchingMap, normal }

    private(set) var needsRelocalization: Bool
    private(set) var normal = false
    private(set) var anchorsPresent = false
    private(set) var interrupted = false
    private(set) var failed = false

    init(restoring: Bool = false) { needsRelocalization = restoring }

    var canPlace: Bool { normal && !interrupted && !failed && !needsRelocalization }
    var canDisplay: Bool { canPlace && anchorsPresent }

    mutating func trackingChanged(_ signal: Signal) {
        guard !interrupted, !failed, signal != .normal else { return }
        normal = false
        anchorsPresent = false
        if signal == .matchingMap { needsRelocalization = true }
    }

    mutating func receivedFrame(_ signal: Signal, allExpectedAnchors: Bool) {
        guard !interrupted, !failed else { return }
        guard signal == .normal else { trackingChanged(signal); return }
        normal = true
        anchorsPresent = allExpectedAnchors
        if anchorsPresent { needsRelocalization = false }
    }

    mutating func pointsChanged() { anchorsPresent = false }

    /// Explicitly pausing the same session revokes readiness without inventing a relocalization event.
    mutating func pause() {
        normal = false
        anchorsPresent = false
    }

    mutating func interrupt() {
        interrupted = true
        needsRelocalization = true
        normal = false
        anchorsPresent = false
    }

    mutating func resume() { interrupted = false }

    mutating func fail() {
        failed = true
        normal = false
        anchorsPresent = false
    }
}
