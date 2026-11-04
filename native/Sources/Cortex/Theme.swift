import SwiftUI
import AppKit

/// Shared look: radii, rims and the artwork wash used across the palette, Dock, Island and widgets.
enum Theme {
    enum Radius {
        static let card: CGFloat = 26
        static let row: CGFloat = 15
        static let sheet: CGFloat = 28
    }
}

extension NSView {
    /// Clips the view's layer to a rounded rectangle and clears its background, so a borderless
    /// panel never shows square corners behind the glass.
    func roundCorners(_ radius: CGFloat) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

extension View {
    /// A thin specular rim, lit from the top-left, like the edge of real glass.
    func glassRim(cornerRadius: CGFloat, strength: Double = 1) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.34 * strength), Color.white.opacity(0.04 * strength), Color.white.opacity(0.16 * strength)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.8)
                .allowsHitTesting(false)
        )
    }
}

/// The cover art, shrunk to a few pixels and stretched back out: bilinear scaling gives the soft
/// ambient wash for free, so nothing is blurred at render time.
struct ArtworkBackdrop: View {
    let image: NSImage
    var strength: Double = 0.55

    private static var cache: (NSImage, NSImage)?

    private static func tiny(_ source: NSImage) -> NSImage {
        if let (k, v) = cache, k === source { return v }
        let side = 24
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        cache = (source, out)
        return out
    }

    var body: some View {
        Image(nsImage: Self.tiny(image))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .saturation(1.35)
            .opacity(strength)
            .overlay(Color.black.opacity(0.32))
            .clipped()
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// The Cortex menu-bar glyph: an open "C" with a spark, drawn as a template so macOS tints it.
enum MenuBarIcon {
    static func image() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 8.2, y: 9), radius: 6.2, startAngle: 38, endAngle: 322, clockwise: false)
            arc.lineWidth = 1.9
            arc.lineCapStyle = .round
            arc.stroke()
            // Four-point spark in the opening.
            let c = NSPoint(x: 13.2, y: 9)
            let pts: [(CGFloat, CGFloat)] = [(0, 3.0), (0.95, 0.95), (3.0, 0), (0.95, -0.95), (0, -3.0), (-0.95, -0.95), (-3.0, 0), (-0.95, 0.95)]
            let star = NSBezierPath()
            for (i, p) in pts.enumerated() {
                let pt = NSPoint(x: c.x + p.0, y: c.y + p.1)
                if i == 0 { star.move(to: pt) } else { star.line(to: pt) }
            }
            star.close()
            star.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
