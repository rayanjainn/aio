import AppKit
import Combine

/// Where the notch is (or where the pill sits on a Mac without one).
struct NotchGeometry: Equatable {
    var screenFrame: NSRect
    var hasNotch: Bool
    var notchWidth: CGFloat
    var menuBarHeight: CGFloat

    @MainActor
    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        // Notch screen if there is one, else the screen that owns the menu bar (always first).
        let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first
        guard let screen else {
            return NotchGeometry(screenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900), hasNotch: false, notchWidth: 0, menuBarHeight: 24)
        }
        let inset = screen.safeAreaInsets.top
        var width: CGFloat = 0
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = max(0, screen.frame.width - left.width - right.width)
        }
        let bar = inset > 0 ? inset : max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(screenFrame: screen.frame, hasNotch: width > 0, notchWidth: width, menuBarHeight: bar)
    }
}

/// Everything the Island view draws from.
@MainActor
final class IslandModel: ObservableObject {
    enum Flash: Equatable { case charging(Int) }

    @Published var geometry = NotchGeometry.detect()
    @Published var expanded = false
    @Published var flash: Flash?
    @Published var track: NowPlayingInfo?
    @Published var battery: Int?
    @Published var charging = false

    static let wing: CGFloat = 64
    static let virtualNotchWidth: CGFloat = 150
    static let expandedSize = CGSize(width: 520, height: 150)

    var hasActivity: Bool { flash != nil || track != nil }

    /// Size of the black pill for the current state. `.zero` = nothing to show.
    func pillSize() -> CGSize {
        let g = geometry
        if expanded {
            return CGSize(width: Self.expandedSize.width, height: g.menuBarHeight + Self.expandedSize.height)
        }
        let gap: CGFloat = g.hasNotch ? g.notchWidth : Self.virtualNotchWidth
        if hasActivity { return CGSize(width: gap + Self.wing * 2, height: g.menuBarHeight) }
        // No notch: draw a small "virtual notch" so there is always something to hover.
        return CGSize(width: g.hasNotch ? g.notchWidth + 4 : Self.virtualNotchWidth, height: g.menuBarHeight)
    }
}
