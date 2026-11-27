import CoreGraphics
import CoreText
import Foundation

/// Original sign artwork, rasterized without UIKit and used as a world-space texture.
enum RouteSignArtwork {
    static func groundRing() -> CGImage? {
        guard let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                                      bytesPerRow: 384, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setStrokeColor(CGColor(red: 0.0, green: 0.78, blue: 0.66, alpha: 1))
        context.setLineWidth(10)
        context.strokeEllipse(in: CGRect(x: 5, y: 5, width: 86, height: 86))
        return context.makeImage()
    }

    /// Text stays on a front-facing transparent plane; the symbol is a separate solid mesh.
    /// Preserve the previous 500 px/metre density and 60 px font rather than upscaling the texture.
    static func label(title: String) -> CGImage? {
        let width = 440, height = 90
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, 60, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, 60, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: attributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
        let line = CTLineCreateTruncatedLine(full, Double(width - 24), .end, token) ?? full
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let origin = CGPoint(x: CGFloat(width) / 2 - bounds.midX, y: CGFloat(height) / 2 - bounds.midY)
        context.textMatrix = .identity
        // Project readability trial: a soft shadow instead of a hard glyph outline.
        context.setShadow(offset: .zero, blur: 4, color: CGColor(gray: 0, alpha: 0.75))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setTextDrawingMode(.fill)
        context.textPosition = origin
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
