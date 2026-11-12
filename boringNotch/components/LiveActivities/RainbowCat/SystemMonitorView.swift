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
        // Capacities and temperature are only in the BatteryData dictionary
        // on recent macOS; the top level is tried as well, for older ones.
        let data = value("BatteryData") as? [String: Any] ?? [:]
        func detail(_ key: String) -> Double? { (data[key] as? NSNumber)?.doubleValue ?? number(key) }
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
        if let design = detail("DesignCapacity"), design > 0,
           let full = detail("NominalChargeCapacity") ?? detail("AppleRawMaxCapacity"), full > 0 {
            battery.health = min(full / design, 1)
        }
        battery.cycles = (value("CycleCount") as? NSNumber)?.intValue
        // Hundredths of a degree Celsius.
        if let raw = detail("Temperature"), raw > 0 { battery.temperature = raw / 100 }
        return battery
    }
}

@MainActor
final class SystemMonitorModel: ObservableObject {
    /// Shared, so the history outlives the panel: it is kept up by the
    /// cat's own load readings while the panel is closed.
    static let shared = SystemMonitorModel()

    @Published private(set) var snapshot = SystemMonitorSnapshot()
    @Published private(set) var cpuHistory: [TimedValue] = []
    @Published private(set) var memoryHistory: [TimedValue] = []
    @Published private(set) var downloadHistory: [TimedValue] = []
    @Published private(set) var uploadHistory: [TimedValue] = []
    @Published private(set) var energy: [BatteryUsageEntry] = []

    private let reader = SystemMonitorReader()
    /// The sparklines show this much time; readings are placed by when they
    /// were taken, so a second apart and two apart line up the same.
    static let window: TimeInterval = 60
    /// Every second while the panel is open; the cat's two-second readings
    /// keep the history going while it is closed.
    private static let openInterval: TimeInterval = 1
    private var ticks = 0

    /// Readings taken while the panel is closed. Kept apart from the
    /// published history, so nothing is told about them until it opens.
    private var pending: [(time: TimeInterval, sample: SystemStatsSample)] = []

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A reading taken for the cat's pace, kept for the panel's history.
    func record(_ sample: SystemStatsSample) {
        guard !isRunning else { return }
        let time = Self.now
        pending = pending.filter { time - $0.time <= Self.window } + [(time, sample)]
    }

    private func takePending() {
        for (time, sample) in pending {
            add(cpu: sample.cpu, memory: sample.memoryTotal > 0 ? sample.memoryFraction : nil,
                download: sample.download, upload: sample.upload, at: time)
        }
        pending = []
    }

    private func add(cpu: Double?, memory: Double?, download: Double?, upload: Double?, at time: TimeInterval) {
        func appending(_ value: Double?, to history: [TimedValue]) -> [TimedValue] {
            guard let value else { return history }
            return history.filter { time - $0.time <= Self.window + 2 } + [TimedValue(time: time, value: value)]
        }
        cpuHistory = appending(cpu, to: cpuHistory)
        memoryHistory = appending(memory, to: memoryHistory)
        downloadHistory = appending(download, to: downloadHistory)
        uploadHistory = appending(upload, to: uploadHistory)
    }

    private var isRunning = false

    func run() async {
        isRunning = true
        defer { isRunning = false }
        takePending()
        ticks = 0
        _ = reader.sample()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(ticks == 0 ? 0.4 : Self.openInterval))
            guard !Task.isCancelled else { return }
            let next = reader.sample()
            snapshot = next
            add(cpu: next.cpu?.total, memory: next.memory.total > 0 ? next.memory.fraction : nil,
                download: next.download, upload: next.upload, at: Self.now)
            // Energy comes through the helper and changes slowly.
            if ticks % 10 == 0 { energy = await BatteryUsageReader.read(limit: 3) }
            ticks += 1
        }
    }
}

struct TimedValue {
    let time: TimeInterval
    let value: Double
}

// MARK: Views

struct SystemMonitorHeader: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        GeometryReader { geometry in
            let centre = vm.closedNotchSize.width
            let side = max(0, (geometry.size.width - centre) / 2)
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SystemMonitorView.cpuTint)
                    Text("System Monitor")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.leading, 10)
                .frame(width: side, height: geometry.size.height, alignment: .leading)
                Rectangle().fill(vm.hasNotch ? .black : .clear).frame(width: centre)
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(Self.uptime())
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
                .frame(width: side, height: geometry.size.height, alignment: .trailing)
            }
        }
    }

    private static func uptime() -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        // In the app's own language, not the region's.
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        let value = formatter.string(from: ProcessInfo.processInfo.systemUptime) ?? "—"
        return String(localized: "Up \(value)")
    }
}

/// One panel, not cards: live load across the top (CPU, memory, network,
/// each with a minute of history), the devices and the apps using energy
/// below, divided by space and hairlines. Clicking one of the top three
/// shows its breakdown in place of the history.
struct SystemMonitorView: View {
    static let cpuTint = Color(red: 0.42, green: 0.62, blue: 1.0)
    static let memoryTint = Color(red: 0.70, green: 0.58, blue: 0.96)
    static let networkTint = Color(red: 0.42, green: 0.80, blue: 0.80)
    static let storageTint = Color(red: 0.86, green: 0.72, blue: 0.46)
    static let batteryTint = Color(red: 0.45, green: 0.85, blue: 0.48)
    private static let appTints: [Color] = [
        Color(red: 0.92, green: 0.62, blue: 0.40), Color(red: 0.62, green: 0.66, blue: 0.76),
        Color(red: 0.55, green: 0.70, blue: 0.95),
    ]

    private enum Detail { case cpu, memory, network }

    @ObservedObject private var model = SystemMonitorModel.shared
    @State private var detail: Detail?

    var body: some View {
        let s = model.snapshot
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                loadColumn(.cpu) { cpuColumn(s) }
                hairline
                loadColumn(.memory) { memoryColumn(s) }
                hairline
                loadColumn(.network) { networkColumn(s) }
            }
            .frame(height: 62)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 6)
            // Equal heights, so each column's last line sits on one baseline.
            HStack(alignment: .top, spacing: 18) {
                storageColumn(s)
                batteryColumn(s)
                energyColumn
            }
            .frame(height: 60)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.disablesAnimations = true }
        .task { await model.run() }
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).padding(.horizontal, 14)
    }

    // MARK: Top: live load

    private func loadColumn<Content: View>(_ kind: Detail, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { detail = detail == kind ? nil : kind }
    }

    private func columnTitle(_ title: String, _ kind: Detail) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 4)
            Image(systemName: detail == kind ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func bigValue(_ number: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: number)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
            Text(verbatim: unit)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// The figure on the left; its history, or once clicked its breakdown,
    /// fills the rest of the row, so opening one keeps the panel's height.
    private func valueRow(
        _ number: String, unit: String, history: [TimedValue], maximum: Double?, tint: Color,
        kind: Detail, breakdown rows: [(String, String)]
    ) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            bigValue(number, unit: unit)
            if detail == kind {
                breakdown(rows)
            } else {
                Sparkline(values: history, maximum: maximum, tint: tint)
            }
        }
        .frame(height: 32, alignment: .bottom)
    }

    private func footer(_ leading: String, _ trailing: some View) -> some View {
        HStack {
            Text(leading)
            Spacer(minLength: 4)
            trailing
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func breakdown(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                HStack {
                    Text(rows[index].0).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(rows[index].1).monospacedDigit()
                }
            }
        }
        .font(.system(size: 9))
        .lineLimit(1)
    }

    private func cpuColumn(_ s: SystemMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            columnTitle("CPU", .cpu)
            valueRow(Self.number(s.cpu?.total), unit: "%", history: model.cpuHistory, maximum: 1, tint: Self.cpuTint,
                     kind: .cpu, breakdown: [
                        (String(localized: "System"), Self.percent(s.cpu?.system)),
                        (String(localized: "User"), Self.percent(s.cpu?.user)),
                        (String(localized: "Idle"), Self.percent(s.cpu?.idle)),
                     ])
            footer(String(localized: "Last 60 seconds"), Text("Load"))
        }
    }

    private func memoryColumn(_ s: SystemMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            columnTitle(String(localized: "Memory"), .memory)
            valueRow(Self.number(s.memory.total > 0 ? s.memory.fraction : nil), unit: "%",
                     history: model.memoryHistory, maximum: 1, tint: Self.memoryTint,
                     kind: .memory, breakdown: [
                    (String(localized: "App"), Self.bytes(s.memory.app)),
                    (String(localized: "Wired"), Self.bytes(s.memory.wired)),
                    (String(localized: "Compressed"), Self.bytes(s.memory.compressed)),
                ])
            footer(String(localized: "Memory pressure"), HStack(spacing: 4) {
                Circle().fill(Self.pressureColor(s.memory.pressure)).frame(width: 5, height: 5)
                Text(verbatim: Self.percent(s.memory.pressure)).monospacedDigit()
            })
        }
    }

    private func networkColumn(_ s: SystemMonitorSnapshot) -> some View {
        let download = Self.rate(s.download)
        return VStack(alignment: .leading, spacing: 2) {
            columnTitle(String(localized: "Network"), .network)
            valueRow(download.number, unit: download.unit, history: model.downloadHistory, maximum: nil,
                     tint: Self.networkTint, kind: .network, breakdown: [
                    (String(localized: "Upload"), SystemStatsReader.speed(s.upload)),
                    (String(localized: "Peak download"), SystemStatsReader.speed(model.downloadHistory.map(\.value).max())),
                    (String(localized: "Peak upload"), SystemStatsReader.speed(model.uploadHistory.map(\.value).max())),
                ])
            footer(String(localized: "Download"), HStack(spacing: 3) {
                Image(systemName: "arrow.up").font(.system(size: 8, weight: .semibold))
                Text(verbatim: SystemStatsReader.speed(s.upload)).monospacedDigit()
            })
        }
    }

    // MARK: Bottom: devices and apps

    private func sectionTitle(_ icon: String, _ title: String, trailing: String?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(title)
            Spacer(minLength: 4)
            if let trailing { Text(verbatim: trailing).monospacedDigit() }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func storageColumn(_ s: SystemMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("internaldrive", String(localized: "Storage"), trailing: s.disk.map { Self.percent($0.fraction) })
            if let disk = s.disk {
                let free = Self.fileSize(disk.free)
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: free.number).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    Text(verbatim: free.unit + " " + String(localized: "available"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Meter(fraction: disk.fraction, tint: Self.storageTint)
                Spacer(minLength: 3)
                Text(verbatim: String(localized: "Used") + " " + Self.fileBytes(disk.used) + " / " + Self.fileBytes(disk.total))
                    .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func batteryColumn(_ s: SystemMonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let battery = s.battery {
                sectionTitle(battery.charging ? "battery.100.bolt" : "battery.75", String(localized: "Battery"),
                             trailing: battery.temperature.map { String(format: "%.1f°C", $0) })
                Spacer(minLength: 2)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "\(Int((battery.level * 100).rounded()))")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    Text(verbatim: "%").font(.system(size: 10)).foregroundStyle(.secondary)
                    if battery.pluggedIn {
                        Image(systemName: "powerplug.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Self.batteryTint)
                    }
                    Spacer(minLength: 4)
                    if let health = battery.health {
                        Text(verbatim: String(localized: "Health") + " " + Self.wholePercent(health))
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 2)
                Text(verbatim: [
                    battery.pluggedIn ? String(localized: "On power adapter") : String(localized: "On battery"),
                    battery.cycles.map { String(localized: "\($0) cycles") },
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                sectionTitle("powerplug", String(localized: "Power"), trailing: nil)
                Text("On power adapter").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var energyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("bolt", String(localized: "Energy use"), trailing: String(localized: "Share"))
            Spacer(minLength: 2)
            if model.energy.isEmpty {
                Text(verbatim: "—").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(Array(model.energy.prefix(2).enumerated()), id: \.element.id) { index, entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(Self.appTints[index % Self.appTints.count]).frame(width: 5, height: 5)
                        Text(entry.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: Self.percent(entry.share)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10))
                    Meter(fraction: entry.share, tint: Self.appTints[index % Self.appTints.count].opacity(0.8), height: 2)
                }
                .padding(.top, index == 0 ? 0 : 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .help(String(localized: "Share of the energy apps have used since they started"))
    }

    // MARK: Formatting

    private static func number(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.1f", fraction * 100)
    }

    private static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.1f%%", fraction * 100)
    }

    private static func wholePercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func pressureColor(_ pressure: Double?) -> Color {
        guard let pressure else { return .secondary }
        return pressure < 0.5 ? .green : pressure < 0.8 ? .yellow : .red
    }

    /// A rate split into its number and unit, for the large figure.
    private static func rate(_ bytesPerSecond: Double?) -> (number: String, unit: String) {
        guard let bytesPerSecond else { return ("—", "KB/s") }
        let kilobytes = bytesPerSecond / 1000
        if kilobytes >= 1000 { return (String(format: "%.1f", kilobytes / 1000), "MB/s") }
        return (String(format: kilobytes >= 100 ? "%.0f" : "%.1f", kilobytes), "KB/s")
    }

    private static func fileSize(_ bytes: Int64) -> (number: String, unit: String) {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1000 { return (String(format: "%.2f", gigabytes / 1000), "TB") }
        return (String(format: "%.1f", gigabytes), "GB")
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
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// The last minute of readings as a line over a fading fill, newest on the
/// right, each at the time it was taken. Without a maximum the scale
/// follows the largest reading shown.
private struct Sparkline: View {
    let values: [TimedValue]
    let maximum: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let latest = values.last?.time ?? 0
            let shown = values.filter { latest - $0.time <= SystemMonitorModel.window }
            let top = max(maximum ?? (shown.map(\.value).max() ?? 0), 0.0001)
            let points = shown.map { reading in
                CGPoint(x: geometry.size.width * CGFloat(1 - (latest - reading.time) / SystemMonitorModel.window),
                        y: 1 + (geometry.size.height - 2) * (1 - CGFloat(min(reading.value / top, 1))))
            }
            if points.count > 1 {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: points[0])
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                }
                // The oldest readings fade in, so the line and its fill have
                // no hard edge where the history begins.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: min(0.35, 18 / max(points[points.count - 1].x - points[0].x, 1))),
                        ],
                        startPoint: UnitPoint(x: points[0].x / max(geometry.size.width, 1), y: 0.5),
                        endPoint: UnitPoint(x: 1, y: 0.5)
                    )
                }
            }
        }
        .frame(height: 18)
    }
}
