import CoreGraphics
import SwiftUI

struct GuidePresentation {
    var localized = false
    var recovering = false
    var coaching = false
    var sessionFailed = false
    var destination = ""
    var message = ""
    var photo: CGImage?
    var language = RouteLanguage.current
}

struct GuideOverlayView<OptionsContent: View>: View {
    let presentation: GuidePresentation
    let exit: () -> Void
    let showReference: () -> Void
    @ViewBuilder let options: () -> OptionsContent
    @State private var footerHeight: CGFloat = 180

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !presentation.coaching {
                    VStack {
                        LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: geometry.safeAreaInsets.top + 80)
                        Spacer(minLength: 0)
                        LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(geometry.size.height * 0.43 + 48, footerHeight + 72))
                    }.ignoresSafeArea().allowsHitTesting(false)
                }
                VStack(spacing: 0) {
                    HStack {
                        Button(action: exit) { CameraToolSymbol(name: "xmark") }
                            .buttonStyle(CameraPressStyle())
                            .accessibilityLabel(text("End navigation", "结束导航")).accessibilityIdentifier("guide.exit")
                        Spacer()
                        if !presentation.coaching, presentation.localized {
                            Menu(content: options) { CameraToolSymbol(name: "slider.horizontal.3") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(text("Sign position", "路标位置")).accessibilityIdentifier("guide.placement")
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                    Spacer(minLength: 0)
                    if !presentation.coaching {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if !presentation.localized, !presentation.recovering, let photo = presentation.photo {
                                    Button(action: showReference) {
                                        HStack(spacing: 14) {
                                            Image(decorative: photo, scale: 1).resizable().scaledToFill()
                                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
                                            Text(text("Reference view", "参考视角")).font(.subheadline)
                                            Spacer(minLength: 0)
                                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).padding(.bottom, 10)
                                    .accessibilityLabel(text("Enlarge reference photo", "放大参考照")).accessibilityIdentifier("guide.reference")
                                }
                                Text(presentation.localized
                                     ? presentation.destination.replacingOccurrences(of: "\n", with: " ")
                                     : presentation.destination)
                                    .font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                                    .accessibilityIdentifier("guide.destination")
                                if !presentation.localized {
                                    Text(instruction).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("guide.instruction")
                                    if !presentation.message.isEmpty {
                                        Text(presentation.message).font(.body).foregroundStyle(.white.opacity(0.88))
                                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("guide.detail")
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                        }
                        .frame(height: min(footerHeight, geometry.size.height * 0.43))
                        .padding(.horizontal, 26).padding(.bottom, 22)
                    }
                }
            }
            .foregroundStyle(.white).colorScheme(.dark)
        }
    }

    private func text(_ en: String, _ zh: String) -> String { presentation.language.select(en, zh) }
    private var instruction: String {
        if presentation.sessionFailed { return text("Tracking stopped", "追踪已停止") }
        return presentation.recovering ? text("Restoring the route", "恢复路线")
            : text("Matching surroundings", "识别周围环境")
    }
}
