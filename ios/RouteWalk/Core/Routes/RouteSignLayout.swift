import simd

/// Metre offsets from a surveyed walking point. Positive lateral offset is to a walker's right.
struct RouteSignPlacement: Equatable {
    var height: Float = 1.1
    var sideOffset: Float = 0.5
}

enum RouteSignLayout {
    struct Descriptor: Equatable {
        let index: Int
        let groundPosition: SIMD3<Float>
        let position: SIMD3<Float>
        let yaw: Float
        let symbol: String
        let title: String
    }

    static func descriptors(points: [SIMD3<Float>], isGuidance: Bool,
                            placement: RouteSignPlacement = RouteSignPlacement(),
                            destinationLabel: String? = nil,
                            recordingFromDestination: Bool = false,
                            language: RouteLanguage = .current) -> [Descriptor] {
        let reverseCapture = !isGuidance && recordingFromDestination
        let points = reverseCapture ? Array(points.reversed()) : points
        return points.indices.compactMap { index in
            let position = points[index]
            let toward = index + 1 < points.count ? direction(from: position, to: points[index + 1]) : nil
            let incoming = index > 0 ? direction(from: points[index - 1], to: position) : nil
            // Before a second point defines a route heading, show the point using
            // the session's initial forward axis; its world-space centre stays fixed.
            guard let approach = incoming ?? toward ?? (!isGuidance ? SIMD3<Float>(0, 0, -1) : nil) else { return nil }
            let right = simd_cross(approach, SIMD3<Float>(0, 1, 0))
            let instruction: (String, String)
            if toward == nil && isGuidance {
                instruction = ("end", destinationLabel ?? language.select("Destination", "终点"))
            } else if toward == nil {
                instruction = ("point", reverseCapture ? language.select("Destination", "终点")
                    : index == 0 ? language.select("Start", "起点") : language.select("Waypoint", "路点"))
            } else if let incoming, let toward {
                let angle = atan2(simd_dot(toward, right), simd_dot(incoming, toward))
                // Project instruction bands: 45° diagonal, 70° turn, 150° return.
                // The 1e-6 rad tolerance only absorbs Float error at exact boundaries.
                let magnitude = abs(angle) + 0.000001
                let isRight = angle > 0
                switch angle {
                case _ where magnitude >= 5 * Float.pi / 6: instruction = ("back", language.select("Turn back", "折返"))
                case _ where magnitude >= 70 * Float.pi / 180:
                    instruction = isRight ? ("right", language.select("Turn right", "右转"))
                        : ("left", language.select("Turn left", "左转"))
                case _ where magnitude >= Float.pi / 4:
                    instruction = isRight ? ("forward-right", language.select("Bear right", "右前方"))
                        : ("forward-left", language.select("Bear left", "左前方"))
                default: instruction = ("up", language.select("Go straight", "直行"))
                }
            } else {
                instruction = ("up", language.select("Start", "起点"))
            }
            return Descriptor(index: index, groundPosition: position,
                              position: position + right * placement.sideOffset + SIMD3<Float>(0, placement.height, 0),
                              yaw: atan2(-approach.x, -approach.z), symbol: instruction.0, title: instruction.1)
        }
    }

    private static func direction(from start: SIMD3<Float>, to end: SIMD3<Float>) -> SIMD3<Float>? {
        let delta = SIMD3<Float>(end.x - start.x, 0, end.z - start.z)
        let length = simd_length(delta)
        return length > 0.001 && length.isFinite ? delta / length : nil
    }
}
