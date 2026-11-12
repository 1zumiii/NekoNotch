//
//  SystemMonitorView.swift
//  boringNotch
//
//  The panel that opens from the rainbow cat: CPU, memory, network, disk,
//  battery and the apps using the most energy. It replaces the system cards
//  the dashboard used to have. Everything is read only while it is open.
//
import Darwin
import IOKit
import SwiftUI

struct SystemMonitorSnapshot {
    struct CPU { var user = 0.0, system = 0.0, idle = 1.0; var total: Double { user + system } }
    struct Memory {
        var used: UInt64 = 0, total: UInt64 = 0
        var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
        var pressure: Double?
        var fraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }
    }
    struct Disk { var total: Int64 = 0, free: Int64 = 0; var used: Int64 { max(total - free, 0) }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 } }
    struct Battery {
        var level: Double = 0
        var pluggedIn = false, charging = false
        var health: Double?, cycles: Int?, temperature: Double?
    }

    var cpu: CPU?
    var memory = Memory()
    var download: Double?
    var upload: Double?
    var disk: Disk?
    var battery: Battery?
}

/// Reads what the panel shows. Rates and the CPU split need two readings,
/// so the previous ones are kept.
final class SystemMonitorReader {
    private let stats = SystemStatsReader()
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64)?

    func sample() -> SystemMonitorSnapshot {
        let base = stats.sample()
        var snapshot = SystemMonitorSnapshot()
        snapshot.cpu = cpuSplit()
        snapshot.memory = Self.memory()
        snapshot.download = base.download
        snapshot.upload = base.upload
        snapshot.disk = Self.disk()
        snapshot.battery = Self.battery()
        return snapshot
    }

    private func cpuSplit() -> SystemMonitorSnapshot.CPU? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let now = (user: UInt64(ticks.0) + UInt64(ticks.3), system: UInt64(ticks.1), idle: UInt64(ticks.2))
        defer { lastTicks = now }
        guard let last = lastTicks, now.user >= last.user, now.system >= last.system, now.idle >= last.idle else { return nil }
        let user = Double(now.user - last.user), system = Double(now.system - last.system), idle = Double(now.idle - last.idle)
        let total = user + system + idle
        guard total > 0 else { return nil }
        return .init(user: user / total, system: system / total, idle: idle / total)
    }

    /// The parts Activity Monitor shows, and the pressure the kernel reports
    /// as the share of memory still free for use.
    private static func memory() -> SystemMonitorSnapshot.Memory {
        var memory = SystemMonitorSnapshot.Memory(total: ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            memory.app = (internalPages - min(UInt64(stats.purgeable_count), internalPages)) * page
            memory.wired = UInt64(stats.wire_count) * page
            memory.compressed = UInt64(stats.compressor_page_count) * page
            memory.used = min(memory.app + memory.wired + memory.compressed, memory.total)
        }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, (0...100).contains(level) {
            memory.pressure = Double(100 - level) / 100
        }
        return memory
    }

    private static func disk() -> SystemMonitorSnapshot.Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return .init(total: Int64(total), free: free)
    }

    /// The smart battery's own figures, one property at a time instead of
    /// copying its whole registry entry.
    private static func battery() -> SystemMonitorSnapshot.Battery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        func value(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func number(_ key: String) -> Double? { (value(key) as? NSNumber)?.doubleValue }
        var battery = SystemMonitorSnapshot.Battery()
        guard let current = number("CurrentCapacity") else { return nil }
        // Apple silicon reports the charge in percent; older Macs in mAh.
        if let max = number("MaxCapacity"), max > 100 {
            battery.level = min(current / max, 1)
        } else {
            battery.level = min(current / 100, 1)
        }
        battery.pluggedIn = (value("ExternalConnected") as? Bool) ?? false
        battery.charging = (value("IsCharging") as? Bool) ?? false
        if let design = number("DesignCapacity"), design > 0,
           let full = number("NominalChargeCapacity") ?? number("AppleRawMaxCapacity"), full > 0 {
            battery.health = min(full / design, 1)
        }
        battery.cycles = (value("CycleCount") as? NSNumber)?.intValue
        if let raw = number("Temperature"), raw > 0 { battery.temperature = raw / 100 }
        return battery
    }
}

@MainActor
final class SystemMonitorModel: ObservableObject {
    @Published private(set) var snapshot = SystemMonitorSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var energy: [BatteryUsageEntry] = []

    private let reader = SystemMonitorReader()
    static let historyLength = 30
    private var ticks = 0

    func run() async {
        _ = reader.sample()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(ticks == 0 ? 0.4 : 2))
            guard !Task.isCancelled else { return }
            let next = reader.sample()
            snapshot = next
            if let cpu = next.cpu { cpuHistory = Array((cpuHistory + [cpu.total]).suffix(Self.historyLength)) }
            if let down = next.download { downloadHistory = Array((downloadHistory + [down]).suffix(Self.historyLength)) }
            // Energy comes through the helper and changes slowly.
            if ticks % 5 == 0 { energy = await BatteryUsageReader.read(limit: 3) }
            ticks += 1
        }
    }
}

// MARK: Views

struct SystemMonitorHeader: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        GeometryReader { geometry in
            let centre = vm.closedNotchSize.width
            let side = max(0, (geometry.size.width - centre) / 2)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .foregroundStyle(SystemMonitorView.tint)
                    Text("System Monitor")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.leading, 14)
                .frame(width: side, height: geometry.size.height, alignment: .leading)
                Rectangle().fill(vm.hasNotch ? .black : .clear).frame(width: centre)
                Text(Self.uptime())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
                    .frame(width: side, height: geometry.size.height, alignment: .trailing)
            }
        }
    }

    private static func uptime() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        let value = formatter.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
        return String(localized: "Up \(value)")
    }
}

struct SystemMonitorView: View {
    static let tint = Color(red: 0.42, green: 0.62, blue: 1.0)
    @StateObject private var model = SystemMonitorModel()

    private static let memoryTint = Color(red: 0.74, green: 0.52, blue: 1.0)
    private static let networkTint = Color(red: 0.30, green: 0.78, blue: 0.86)
    private static let diskTint = Color(red: 0.30, green: 0.78, blue: 0.62)
    private static let batteryTint = Color(red: 0.42, green: 0.84, blue: 0.40)
    private static let energyTint = Color(red: 0.96, green: 0.76, blue: 0.26)

    var body: some View {
        let s = model.snapshot
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                tile(icon: "cpu", tint: Self.tint, title: "CPU", value: Self.percent(s.cpu?.total),
                     details: [
                        (String(localized: "System"), Self.percent(s.cpu?.system)),
                        (String(localized: "User"), Self.percent(s.cpu?.user)),
                        (String(localized: "Idle"), Self.percent(s.cpu?.idle)),
                     ]) {
                    Sparkline(values: model.cpuHistory, maximum: 1, tint: Self.tint)
                }
                tile(icon: "memorychip", tint: Self.memoryTint, title: String(localized: "Memory"),
                     value: Self.percent(s.memory.total > 0 ? s.memory.fraction : nil),
                     details: [
                        (String(localized: "Pressure"), Self.percent(s.memory.pressure)),
                        (String(localized: "App"), Self.bytes(s.memory.app)),
                        (String(localized: "Wired"), Self.bytes(s.memory.wired)),
                        (String(localized: "Compressed"), Self.bytes(s.memory.compressed)),
                     ]) {
                    Meter(fraction: s.memory.fraction, tint: Self.memoryTint)
                }
                tile(icon: "network", tint: Self.networkTint, title: String(localized: "Network"),
                     value: nil,
                     details: [
                        (String(localized: "Download"), SystemStatsReader.speed(s.download)),
                        (String(localized: "Upload"), SystemStatsReader.speed(s.upload)),
                     ]) {
                    Sparkline(values: model.downloadHistory, maximum: nil, tint: Self.networkTint)
                }
            }
            GridRow {
                tile(icon: "internaldrive", tint: Self.diskTint, title: String(localized: "Storage"),
                     value: Self.percent(s.disk?.fraction),
                     details: s.disk.map { disk in [
                        (String(localized: "Used"), Self.fileBytes(disk.used)),
                        (String(localized: "Free"), Self.fileBytes(disk.free)),
                        (String(localized: "Total"), Self.fileBytes(disk.total)),
                     ] } ?? []) {
                    Meter(fraction: s.disk?.fraction ?? 0, tint: Self.diskTint)
                }
                if let battery = s.battery {
                    tile(icon: battery.charging ? "battery.100.bolt" : "battery.75", tint: Self.batteryTint,
                         title: String(localized: "Battery"), value: Self.percent(battery.level),
                         details: [
                            (String(localized: "Power"), battery.pluggedIn ? String(localized: "Adapter") : String(localized: "Battery")),
                            (String(localized: "Health"), Self.percent(battery.health)),
                            (String(localized: "Cycles"), battery.cycles.map(String.init) ?? "—"),
                            (String(localized: "Temperature"), battery.temperature.map { String(format: "%.1f°C", $0) } ?? "—"),
                         ]) {
                        Meter(fraction: battery.level, tint: Self.batteryTint)
                    }
                } else {
                    tile(icon: "powerplug", tint: Self.batteryTint, title: String(localized: "Power"),
                         value: nil, details: [(String(localized: "Power"), String(localized: "Adapter"))]) { EmptyView() }
                }
                energyTile
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.disablesAnimations = true }
        .task { await model.run() }
    }

    private var energyTile: some View {
        DashboardCardChrome(tint: Self.energyTint) {
            VStack(alignment: .leading, spacing: 5) {
                Self.titleRow(icon: "bolt.fill", tint: Self.energyTint, title: String(localized: "Energy"), value: nil)
                if model.energy.isEmpty {
                    Text("—").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.energy) { entry in
                        HStack(spacing: 5) {
                            Image(nsImage: entry.icon).resizable().frame(width: 12, height: 12)
                            Text(entry.name).font(.system(size: 10)).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(Self.percent(entry.share))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .help(String(localized: "Share of the energy apps have used since they started"))
    }

    private func tile<Footer: View>(
        icon: String, tint: Color, title: String, value: String?,
        details: [(String, String)], @ViewBuilder footer: () -> Footer
    ) -> some View {
        DashboardCardChrome(tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                Self.titleRow(icon: icon, tint: tint, title: title, value: value)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], alignment: .leading, spacing: 1) {
                    ForEach(details.indices, id: \.self) { index in
                        HStack(spacing: 3) {
                            Text(details[index].0).foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text(details[index].1).monospacedDigit()
                        }
                        .font(.system(size: 9.5))
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                footer()
            }
        }
    }

    private static func titleRow(icon: String, tint: Color, title: String, value: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.18)))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            if let value {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.1f%%", fraction * 100)
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private static func fileBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct Meter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// Recent readings as a filled line, newest on the right. Without a maximum
/// the scale follows the largest reading shown.
private struct Sparkline: View {
    let values: [Double]
    let maximum: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let top = max(maximum ?? (values.max() ?? 0), 0.0001)
            let step = geometry.size.width / CGFloat(max(SystemMonitorModel.historyLength - 1, 1))
            let start = geometry.size.width - step * CGFloat(max(values.count - 1, 0))
            let points = values.enumerated().map { index, value in
                CGPoint(x: start + step * CGFloat(index),
                        y: geometry.size.height * (1 - CGFloat(min(value / top, 1))))
            }
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(tint.opacity(0.25))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, lineWidth: 1.2)
                }
            }
        }
        .frame(height: 14)
    }
}
