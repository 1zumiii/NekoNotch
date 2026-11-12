//
//  SystemStatsWidgetView.swift
//  boringNotch
//
import Darwin
import SwiftUI

struct SystemStatsSample {
    /// 0...1 over all cores; nil until there are two readings to compare.
    let cpu: Double?
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    /// Bytes per second; nil until there are two readings to compare.
    let download: Double?
    let upload: Double?

    var memoryFraction: Double {
        memoryTotal > 0 ? min(Double(memoryUsed) / Double(memoryTotal), 1) : 0
    }
}

/// CPU, memory and network, read straight from the kernel. Rates need two
/// readings, so the reader keeps the previous one.
final class SystemStatsReader {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastBytes: (received: UInt64, sent: UInt64, at: TimeInterval)?

    func sample() -> SystemStatsSample {
        let memory = Self.memory()
        let rates = networkRates()
        return SystemStatsSample(
            cpu: cpuUsage(),
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            download: rates?.received,
            upload: rates?.sent
        )
    }

    /// The CPU load alone, for callers that need nothing else.
    func sampleCPU() -> Double? { cpuUsage() }

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0), system = UInt64(ticks.1), idle = UInt64(ticks.2), nice = UInt64(ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let lastTicks, total > lastTicks.total, busy >= lastTicks.busy else { return nil }
        return min(Double(busy - lastTicks.busy) / Double(total - lastTicks.total), 1)
    }

    /// "Memory Used" as Activity Monitor counts it: app memory, wired and
    /// compressed.
    private static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let pageSize = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        return (min(used, total), total)
    }

    private func networkRates() -> (received: Double, sent: Double)? {
        guard let bytes = Self.interfaceBytes() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastBytes = (bytes.received, bytes.sent, now) }
        guard let lastBytes, now > lastBytes.at else { return nil }
        let elapsed = now - lastBytes.at
        // A counter that went backwards was reset (an interface came back up).
        let received = bytes.received >= lastBytes.received ? Double(bytes.received - lastBytes.received) / elapsed : 0
        let sent = bytes.sent >= lastBytes.sent ? Double(bytes.sent - lastBytes.sent) / elapsed : 0
        return (received, sent)
    }

    /// Bytes through the Wi-Fi and Ethernet interfaces (en*), from the
    /// 64-bit counters. Tunnels are left out: a VPN's traffic also passes
    /// through the interface under it and would count twice.
    private static func interfaceBytes() -> (received: UInt64, sent: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let isUp = message.ifm_flags & IFF_UP != 0
                    let isLoopback = message.ifm_flags & IFF_LOOPBACK != 0
                    if isUp, !isLoopback, if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil,
                       String(cString: nameBuffer).hasPrefix("en") {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }
}

extension SystemStatsReader {
    /// A transfer rate such as "1.2 MB/s", or a dash before the second reading.
    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }
}
