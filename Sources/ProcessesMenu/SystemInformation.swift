import Foundation
import Darwin

struct SystemInformation: Sendable {
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let freeDiskBytes: UInt64?
    let uptime: TimeInterval

    var cpuText: String { cpuPercent.map { "\(Int($0.rounded())) %" } ?? "—" }
    var diskText: String { freeDiskBytes.map(Self.bytes) ?? "—" }
    var compactMemoryText: String {
        guard let memoryBytes else { return "—" }
        let gib = Double(1 << 30)
        return String(format: "%.1f / %.0f ГБ", locale: Locale.current,
                      Double(memoryBytes) / gib, Double(ProcessInfo.processInfo.physicalMemory) / gib)
    }
    var uptimeText: String {
        let minutes = max(0, Int(uptime / 60))
        let days = minutes / 1440
        return (days > 0 ? "\(days) д " : "") + "\(minutes / 60 % 24) ч \(minutes % 60) мин"
    }

    var menuRows: [(symbol: String, title: String)] {
        let memory = memoryBytes.map { "\(Self.bytes($0)) из \(Self.bytes(ProcessInfo.processInfo.physicalMemory))" } ?? "—"
        return [
            ("cpu", "CPU: \(cpuText)"),
            ("memorychip", "Память: \(memory)"),
            ("internaldrive", "Свободно на диске: \(diskText)"),
            ("clock", "Без перезагрузки: \(uptimeText)")
        ]
    }

    static func read() async -> Self {
        await Task.detached(priority: .utility) {
            let first = cpuTicks()
            try? await Task.sleep(nanoseconds: 150_000_000)
            let second = cpuTicks()
            var cpu: Double?
            if let first, let second {
                // Tick counters are UInt32 and may wrap during long uptimes.
                let delta = zip(second, first).map { UInt64($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 {
                    cpu = 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total)
                }
            }
            let disk = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            return Self(cpuPercent: cpu, memoryBytes: usedMemory(),
                        freeDiskBytes: (disk?[.systemFreeSize] as? NSNumber)?.uint64Value,
                        uptime: ProcessInfo.processInfo.systemUptime)
        }.value
    }

    private static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private static func usedMemory() -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Anonymous memory excluding purgeable pages, plus wired and compressed
        // memory. File cache and swap are not counted as occupied physical RAM.
        let appPages = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        return (appPages + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * UInt64(getpagesize())
    }

    private static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory).locale(Locale(identifier: "ru_RU")))
    }
}
