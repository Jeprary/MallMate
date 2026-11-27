/// Camera capability data, independent of ARKit so the fallback policy can be checked without a camera.
struct RouteVideoFormatCapabilities {
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let supportsHDR: Bool

    var pixelCount: Int { width * height }
}

enum RouteVideoFormatSelection {
    /// nil keeps ARKit's default, either because it already supports HDR or no candidate does.
    static func hdrReplacementIndex(defaultFormat: RouteVideoFormatCapabilities,
                                    supportedFormats: [RouteVideoFormatCapabilities]) -> Int? {
        guard !defaultFormat.supportsHDR else { return nil }
        return supportedFormats.indices.filter { supportedFormats[$0].supportsHDR }.min { lhs, rhs in
            let left = preference(supportedFormats[lhs], relativeTo: defaultFormat)
            let right = preference(supportedFormats[rhs], relativeTo: defaultFormat)
            // Preserve ARKit's supported-format order when capabilities have equal preference.
            return left == right ? lhs < rhs : left.lexicographicallyPrecedes(right)
        }
    }

    private static func preference(_ format: RouteVideoFormatCapabilities,
                                   relativeTo original: RouteVideoFormatCapabilities) -> [Int] {
        [abs(format.framesPerSecond - original.framesPerSecond),
         format.framesPerSecond > original.framesPerSecond ? 1 : 0,
         format.pixelCount > original.pixelCount ? 1 : 0,
         abs(format.pixelCount - original.pixelCount)]
    }
}
