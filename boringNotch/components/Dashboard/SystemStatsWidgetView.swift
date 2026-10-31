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

/// CPU and memory as rings, network speed beside them. Read only while the
/// dashboard is on screen.
struct SystemStatsWidgetView: View {
    static let tint = Color(red: 0.42, green: 0.62, blue: 1.0)

    let size: CGSize

    @State private var reader = SystemStatsReader()
    @State private var sample: SystemStatsSample?

    private var isStrip: Bool { size.height < 90 }
    private var title: String { String(localized: "System") }
    private static let icon = "cpu"
    private static let refreshInterval: Duration = .seconds(2)

    var body: some View {
        Group {
            if isStrip {
                strip
            } else {
                card
            }
        }
        .frame(width: size.width, height: size.height)
        // Numbers change every two seconds: easing the rings each time would
        // keep SwiftUI animating most of the time the dashboard is open.
        .transaction { $0.disablesAnimations = true }
        .task {
            while !Task.isCancelled {
                sample = reader.sample()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    // MARK: Two rows tall

    /// Wide enough for both rings with the speeds beside them; narrower
    /// cards put the speeds under the rings.
    private var isWide: Bool { size.width >= 250 }

    private var card: some View {
        DashboardCard(icon: Self.icon, tint: Self.tint, title: title) {
            EmptyView()
        } content: {
            if let sample {
                let contentWidth = size.width - 18
                let diameter = isWide
                    ? min(max(size.height - 18 - 22 - 28, 40), 64)
                    : min(max(size.height - 18 - 22 - 44, 36), (contentWidth - 12) / 2, 60)
                Spacer(minLength: 4)
                HStack(spacing: 0) {
                    Spacer(minLength: 2)
                    GaugeRing(
                        fraction: sample.cpu ?? 0,
                        valueText: Self.percent(sample.cpu),
                        label: String(localized: "CPU"),
                        tint: Self.tint,
                        diameter: diameter
                    )
                    Spacer(minLength: 8)
                    GaugeRing(
                        fraction: sample.memoryFraction,
                        valueText: Self.percent(sample.memoryFraction),
                        label: String(localized: "Memory"),
                        tint: Self.tint,
                        diameter: diameter
                    )
                    .help(Self.bytes(sample.memoryUsed) + " / " + Self.bytes(sample.memoryTotal))
                    if isWide {
                        Spacer(minLength: 10)
                        VStack(alignment: .leading, spacing: 6) {
                            rate(symbol: "arrow.down", value: sample.download)
                            rate(symbol: "arrow.up", value: sample.upload)
                        }
                    }
                    Spacer(minLength: 2)
                }
                if !isWide {
                    Spacer(minLength: 4)
                    HStack(spacing: 12) {
                        rate(symbol: "arrow.down", value: sample.download)
                        rate(symbol: "arrow.up", value: sample.upload)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 4)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func rate(symbol: String, value: Double?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Self.tint)
            Text(verbatim: Self.speed(value))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: One row tall

    private var strip: some View {
        DashboardCardChrome(tint: Self.tint) {
            if let sample {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        DashboardCardTitle(icon: Self.icon, tint: Self.tint, title: title)
                        MiniGauge(
                            fraction: sample.cpu ?? 0, valueText: Self.percent(sample.cpu),
                            label: String(localized: "CPU"), tint: Self.tint
                        )
                        MiniGauge(
                            fraction: sample.memoryFraction, valueText: Self.percent(sample.memoryFraction),
                            label: String(localized: "Memory"), tint: Self.tint
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            rate(symbol: "arrow.down", value: sample.download)
                            rate(symbol: "arrow.up", value: sample.upload)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 10) {
                        MiniGauge(
                            fraction: sample.cpu ?? 0, valueText: Self.percent(sample.cpu),
                            label: String(localized: "CPU"), tint: Self.tint
                        )
                        MiniGauge(
                            fraction: sample.memoryFraction, valueText: Self.percent(sample.memoryFraction),
                            label: String(localized: "Memory"), tint: Self.tint
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            rate(symbol: "arrow.down", value: sample.download)
                            rate(symbol: "arrow.up", value: sample.upload)
                        }
                    }
                    .frame(maxHeight: .infinity)

                    // The narrowest strip: gauges on one line, speeds on the next.
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            MiniGauge(
                                fraction: sample.cpu ?? 0, valueText: Self.percent(sample.cpu),
                                label: String(localized: "CPU"), tint: Self.tint
                            )
                            MiniGauge(
                                fraction: sample.memoryFraction, valueText: Self.percent(sample.memoryFraction),
                                label: String(localized: "Memory"), tint: Self.tint
                            )
                        }
                        HStack(spacing: 12) {
                            rate(symbol: "arrow.down", value: sample.download)
                            rate(symbol: "arrow.up", value: sample.upload)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
