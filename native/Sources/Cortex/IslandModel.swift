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
        let wanted = Prefs.shared.islandDisplay
        let screen = (wanted != "auto" ? screens.first(where: { $0.localizedName == wanted }) : nil)
            ?? screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first
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

enum IslandPage: String, CaseIterable, Identifiable {
    case player, calendar, shelf, clipboard, tools
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .player: "music.note"
        case .calendar: "calendar"
        case .shelf: "tray.full"
        case .clipboard: "doc.on.clipboard"
        case .tools: "slider.horizontal.3"
        }
    }
    var title: String {
        switch self {
        case .player: "Player"
        case .calendar: "Calendar"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .tools: "Tools"
        }
    }
}

/// What the compact pill is showing, highest priority first.
enum IslandActivity {
    case hud(HUDEvent)
    case flash(IslandModel.Flash)
    case meeting(MeetingEvent)
    case timer
    case download([String])
    case music
    case privacy
    case idle
}

/// Everything the Island view draws from.
@MainActor
final class IslandModel: ObservableObject {
    enum Flash: Equatable {
        case charging(Int)
        case bluetooth(String, String?)
        case message(String, String)      // symbol, text
    }

    @Published var geometry = NotchGeometry.detect()
    @Published var expanded = false
    @Published var page: IslandPage = .player
    @Published var flash: Flash?
    @Published var hud: HUDEvent?
    @Published var track: NowPlayingInfo?
    @Published var battery: Int?
    @Published var charging = false
    @Published var timerRunning = false
    @Published var meeting: MeetingEvent?
    @Published var downloads: [String] = []
    @Published var micInUse = false
    @Published var cameraInUse = false
    @Published var dragTargeted = false
    @Published var lyric: String?

    static let wing: CGFloat = 64
    static let wideWing: CGFloat = 122
    static let expandedSize = CGSize(width: 580, height: 238)

    var activity: IslandActivity {
        if let hud { return .hud(hud) }
        if let flash { return .flash(flash) }
        if let meeting { return .meeting(meeting) }
        if timerRunning { return .timer }
        if !downloads.isEmpty { return .download(downloads) }
        if track != nil { return .music }
        if micInUse || cameraInUse { return .privacy }
        return .idle
    }

    var hasActivity: Bool { if case .idle = activity { return false } else { return true } }

    /// Width of one wing for the current activity.
    var wingWidth: CGFloat {
        switch activity {
        case .hud, .meeting, .download:
            return Self.wideWing
        case .flash(let f):
            if case .charging = f { return Self.wing }
            return Self.wideWing
        default:
            return Self.wing
        }
    }

    static let virtualNotchWidth: CGFloat = 150

    /// Size of the black pill for the current state. `.zero` = nothing to show.
    func pillSize() -> CGSize {
        let g = geometry
        if expanded {
            return CGSize(width: Self.expandedSize.width, height: g.menuBarHeight + Self.expandedSize.height)
        }
        let gap: CGFloat = g.hasNotch ? g.notchWidth : Self.virtualNotchWidth
        if hasActivity { return CGSize(width: gap + wingWidth * 2, height: g.menuBarHeight) }
        // No notch: draw a small "virtual notch" so there is always something to hover.
        return CGSize(width: g.hasNotch ? g.notchWidth + 4 : Self.virtualNotchWidth, height: g.menuBarHeight)
    }
}
