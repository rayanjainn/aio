import Foundation
import IOKit.ps

/// Battery level / charging state, polled cheaply. `onPlugIn` fires when AC is connected.
final class PowerMonitor: ObservableObject {
    @Published private(set) var percent: Int?
    @Published private(set) var charging = false
    var onPlugIn: ((Int) -> Void)?

    private var timer: Timer?
    private var wasOnAC: Bool?

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let cap = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            percent = cap
            charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            if let was = wasOnAC, !was, onAC { onPlugIn?(cap) }
            wasOnAC = onAC
            return
        }
    }
}
