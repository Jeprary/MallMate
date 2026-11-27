import ARKit
import OSLog

enum RouteCameraConfiguration {
    private static let logger = Logger(subsystem: "com.mallmate.routewalk", category: "ARCamera")

    static func enableSupportedHDR(on configuration: ARWorldTrackingConfiguration) {
        let original = configuration.videoFormat
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let index = RouteVideoFormatSelection.hdrReplacementIndex(
            defaultFormat: capabilities(of: original), supportedFormats: formats.map { capabilities(of: $0) }) {
            configuration.videoFormat = formats[index]
        }
        let selected = configuration.videoFormat
        configuration.videoHDRAllowed = selected.isVideoHDRSupported

        // Reports the selected capture configuration, not measured display HDR or thermal performance.
        logger.notice("AR capture configured: \(Int(selected.imageResolution.width), privacy: .public)x\(Int(selected.imageResolution.height), privacy: .public), \(selected.framesPerSecond, privacy: .public) fps, HDR allowed=\(configuration.videoHDRAllowed, privacy: .public), default retained=\(selected === original, privacy: .public)")
    }

    /// Capture-format metadata only; no images, device identifiers or private photo-output APIs.
    static func diagnosticFields(for configuration: ARWorldTrackingConfiguration) -> [String: String] {
        let format = configuration.videoFormat
        return ["videoWidth": String(Int(format.imageResolution.width)),
                "videoHeight": String(Int(format.imageResolution.height)),
                "videoFPS": String(format.framesPerSecond),
                "videoHDRSupported": String(format.isVideoHDRSupported),
                "videoHDRAllowed": String(configuration.videoHDRAllowed),
                "captureDeviceType": format.captureDeviceType.rawValue,
                "captureDevicePosition": String(format.captureDevicePosition.rawValue),
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
    }

    private static func capabilities(of format: ARConfiguration.VideoFormat) -> RouteVideoFormatCapabilities {
        RouteVideoFormatCapabilities(width: Int(format.imageResolution.width),
                                     height: Int(format.imageResolution.height),
                                     framesPerSecond: format.framesPerSecond,
                                     supportsHDR: format.isVideoHDRSupported)
    }
}
