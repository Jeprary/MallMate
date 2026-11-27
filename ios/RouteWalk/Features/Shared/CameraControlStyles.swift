import SwiftUI

/// Camera tools keep a stable glyph size and a separate, accessible touch target.
struct CameraToolSymbol: View {
    let name: String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

struct CameraPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}
