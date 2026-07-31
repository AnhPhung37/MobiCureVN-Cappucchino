import SwiftUI

private struct TextSizeScaleKey: EnvironmentKey {
    /// Fallback for previews/contexts rendered outside `AppRootView` — unscaled.
    static let defaultValue: CGFloat = TextSizeOption.standard.scaleFactor
}

extension EnvironmentValues {
    var textSizeScale: CGFloat {
        get { self[TextSizeScaleKey.self] }
        set { self[TextSizeScaleKey.self] = newValue }
    }
}

extension View {
    /// Drop-in replacement for `.font(.system(size:weight:design:))` that scales the point size
    /// by the user's Profile > Text Size preference (`\.textSizeScale`, set in `AppRootView`)
    /// instead of using a fixed pixel value.
    func appFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ScaledAppFont(size: size, weight: weight, design: design))
    }
}

private struct ScaledAppFont: ViewModifier {
    @Environment(\.textSizeScale) private var scale
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}
