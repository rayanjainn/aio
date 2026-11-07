import AppKit
import ApplicationServices

/// Turns Caps Lock into a "Hyper" key: held with another key it presses ⌃⌥⌘⇧ together with it.
/// Caps Lock is first remapped to F18 (`hidutil`), then a session event tap adds the four modifiers to
/// every key pressed while F18 is held. Needs Accessibility. The remap is undone when you turn it off or quit.
enum HyperKey {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var held = false

    private static let capsLock = 30064771129   // 0x700000039
    private static let f18 = 30064771181        // 0x70000006D
    private static let f18KeyCode: Int64 = 79

    static var isRunning: Bool { tap != nil }

    private static func hidutil(_ json: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", json]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    @discardableResult
    static func start() -> Bool {
        guard tap == nil else { return true }
        guard WindowManager.isTrusted else { WindowManager.requestAccess(); return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = HyperKey.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == HyperKey.f18KeyCode {
                HyperKey.held = (type == .keyDown)
                return nil   // F18 itself never reaches an app
            }
            if HyperKey.held {
                event.flags.formUnion([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            Log.warn("hyper key: could not create the event tap")
            return false
        }
        hidutil("{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(capsLock),\"HIDKeyboardModifierMappingDst\":\(f18)}]}")
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t; source = src
        Log.info("hyper key: on (Caps Lock → ⌃⌥⌘⇧)")
        return true
    }

    static func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        let wasOn = tap != nil
        tap = nil; source = nil; held = false
        if wasOn { hidutil("{\"UserKeyMapping\":[]}"); Log.info("hyper key: off") }
    }
}
