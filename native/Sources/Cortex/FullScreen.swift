import AppKit

/// Is a full-screen app covering `screen`? A full-screen window covers the whole screen, menu bar included;
/// a maximised one does not.
enum FullScreen {
    static func isCovering(_ screen: NSScreen?) -> Bool {
        guard let scr = screen, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let f = scr.frame
        let cg = CGRect(x: f.minX, y: primary.frame.height - f.maxY, width: f.width, height: f.height)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            if b.width >= cg.width - 1, b.height >= cg.height - 1, abs(b.minX - cg.minX) < 2, abs(b.minY - cg.minY) < 2 { return true }
        }
        return false
    }

    /// Calls `changed` shortly after every Space or app switch, once the transition has settled.
    static func observe(_ changed: @escaping () -> Void) {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { changed() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { changed() }
            }
        }
    }
}
