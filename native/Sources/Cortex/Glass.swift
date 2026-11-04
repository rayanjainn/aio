import SwiftUI

extension View {
    /// Real Liquid Glass on macOS 26+, system material before that.
    @ViewBuilder
    func cortexGlass<S: Shape>(in shape: S, darken: Double = 0) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(darken > 0 ? Glass.regular.tint(Color.black.opacity(darken)) : Glass.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape).background(Color.black.opacity(darken), in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape).background(Color.black.opacity(darken), in: shape)
        #endif
    }
}
