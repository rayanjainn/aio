import Foundation
import Combine
import Darwin

/// CPU, memory and disk figures for the System widget. Only polls while a widget is watching.
final class SystemStats: ObservableObject {
    static let shared = SystemStats()

    @Published private(set) var cpu = 0.0          // 0...1
    @Published private(set) var memoryUsed = 0.0   // bytes
    @Published private(set) var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var diskFree = 0.0     // bytes
    @Published private(set) var diskTotal = 0.0

    private var timer: Timer?
    private var watchers = 0
    private var previous: (busy: UInt64, total: UInt64)?

    func watch() {
        watchers += 1
        if timer == nil {
            sample()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { timer?.invalidate(); timer = nil; previous = nil }
    }

    private func sample() {
        if let c = readCPU() { cpu = c }
        if let m = readMemory() { memoryUsed = m }
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(values.volumeTotalCapacity ?? 0)
        }
    }

    private func readCPU() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(cpuCount) {
            let base = Int(CPU_STATE_MAX) * core
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        defer { previous = (busy, total) }
        guard let p = previous, total > p.total else { return nil }
        return min(1, max(0, Double(busy - p.busy) / Double(total - p.total)))
    }

    private func readMemory() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        return Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * page
    }
}
