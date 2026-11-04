import AppKit
import CoreAudio
import AudioToolbox

enum HUDKind { case volume, brightness }

struct HUDEvent: Equatable {
    let kind: HUDKind
    let level: Double      // 0...1
    let muted: Bool
}

/// Volume and brightness, for the Island's HUD. Volume changes are observed through CoreAudio (any source).
/// When Accessibility is granted, Cortex also takes over the hardware volume / brightness keys, which is
/// what stops the macOS overlay from appearing at the same time.
final class HUDService {
    static let shared = HUDService()

    var onEvent: ((HUDEvent) -> Void)?
    private(set) var keysCaptured = false
    private var tap: CFMachPort?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var lastEmitted: HUDEvent?
    private var lastEmitAt = Date.distantPast

    // MARK: CoreAudio

    private func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    func volume() -> Double? {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = volumeAddress()
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    func setVolume(_ v: Double) {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return }
        var value = Float32(min(max(v, 0), 1))
        var addr = volumeAddress()
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    func isMuted() -> Bool {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = muteAddress()
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    func setMuted(_ m: Bool) {
        let dev = defaultOutputDevice()
        guard dev != 0 else { return }
        var value = UInt32(m ? 1 : 0)
        var addr = muteAddress()
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func emit(_ e: HUDEvent) {
        // The key tap and the CoreAudio listener both report the same change.
        if let last = lastEmitted, last == e, Date().timeIntervalSince(lastEmitAt) < 0.25 { return }
        lastEmitted = e
        lastEmitAt = Date()
        DispatchQueue.main.async { self.onEvent?(e) }
    }

    func startListening() {
        stopListening()
        let dev = defaultOutputDevice()
        guard dev != 0 else { return }
        for var addr in [volumeAddress(), muteAddress()] {
            let status = AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main) { [weak self] _, _ in
                guard let self, let v = self.volume() else { return }
                self.emit(HUDEvent(kind: .volume, level: v, muted: self.isMuted()))
            }
            if status == noErr { listeners.append((dev, addr)) }
        }
    }

    func stopListening() { listeners.removeAll() }

    // MARK: brightness (built-in display, private DisplayServices)

    private lazy var displayServices: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    func brightness() -> Double? {
        typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        guard let h = displayServices, let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        let get = unsafeBitCast(sym, to: Getter.self)
        guard get(CGMainDisplayID(), &value) == 0 else { return nil }
        return Double(value)
    }

    func setBrightness(_ v: Double) {
        typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
        guard let h = displayServices, let sym = dlsym(h, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(sym, to: Setter.self)(CGMainDisplayID(), Float(min(max(v, 0), 1)))
    }

    // MARK: media keys

    /// Takes over the volume / brightness / mute keys (needs Accessibility). Returns false if macOS refuses.
    @discardableResult
    func captureKeys() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, _ in HUDService.shared.handle(type, event) }, userInfo: nil) else {
            Log.warn("HUD: could not tap media keys (Accessibility needed)")
            return false
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        keysCaptured = true
        Log.info("HUD: media keys captured")
        return true
    }

    func releaseKeys() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil
        keysCaptured = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return pass }
        let data = ns.data1
        let code = Int((data & 0xFFFF0000) >> 16)
        let flags = data & 0x0000FFFF
        let isDown = ((flags & 0xFF00) >> 8) == 0xA
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        switch code {
        case 0, 1, 7:   // sound up, sound down, mute
            if isDown { DispatchQueue.main.async { self.volumeKey(code, fine: fine) } }
            return nil
        case 2, 3:      // brightness up, down
            guard brightness() != nil else { return pass }
            if isDown { DispatchQueue.main.async { self.brightnessKey(up: code == 2, fine: fine) } }
            return nil
        default:
            return pass
        }
    }

    private func volumeKey(_ code: Int, fine: Bool) {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        var level = volume() ?? 0
        var muted = isMuted()
        switch code {
        case 0:
            if muted { setMuted(false); muted = false }
            level = min(1, level + step)
            setVolume(level)
        case 1:
            level = max(0, level - step)
            setVolume(level)
            if level == 0 { muted = false }
        default:
            muted.toggle()
            setMuted(muted)
        }
        emit(HUDEvent(kind: .volume, level: level, muted: muted))
    }

    private func brightnessKey(up: Bool, fine: Bool) {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        let level = min(1, max(0, (brightness() ?? 0.5) + (up ? step : -step)))
        setBrightness(level)
        emit(HUDEvent(kind: .brightness, level: level, muted: false))
    }
}
