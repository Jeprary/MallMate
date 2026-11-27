import SwiftUI

struct RouteReviewPresentation {
    var coaching = false
    var message = ""
    var language = RouteLanguage.current
}

/// Browses the route in the same camera session after saving; it does not begin navigation.
struct RouteReviewOverlayView<OptionsContent: View>: View {
    let presentation: RouteReviewPresentation
    let exit: () -> Void
    @ViewBuilder let options: () -> OptionsContent
    @State private var statusHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if !presentation.coaching {
                    LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: geometry.safeAreaInsets.top + 90)
                        .ignoresSafeArea().allowsHitTesting(false)
                }
                VStack(spacing: 12) {
                    HStack {
                        Button(action: exit) { CameraToolSymbol(name: "xmark") }
                            .buttonStyle(CameraPressStyle())
                            .accessibilityLabel(text("Exit review", "退出浏览"))
                            .accessibilityIdentifier("review.exit")
                        Spacer()
                        if !presentation.coaching {
                            Menu(content: options) { CameraToolSymbol(name: "ellipsis") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(text("More", "更多"))
                                .accessibilityIdentifier("review.more")
                        }
                    }
                    .padding(.horizontal, 16)
                    if !presentation.coaching {
                        ScrollView(.vertical) {
                            Text(presentation.message.isEmpty ? text("Preview", "预览") : presentation.message)
                                .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                                .accessibilityIdentifier("review.status")
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusHeight = $0 }
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: min(statusHeight, geometry.size.height * 0.35))
                        .scrollIndicators(.hidden).padding(.horizontal, 24)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
            }
            .foregroundStyle(.white).colorScheme(.dark)
        }
    }

    private func text(_ en: String, _ zh: String) -> String { presentation.language.select(en, zh) }
}
