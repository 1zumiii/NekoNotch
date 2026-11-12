//
//  CPULoadMonitor.swift
//  boringNotch
//
//  Total CPU load for the rainbow cat's pace, read every two seconds and
//  only while a cat is on screen. The same reading keeps the system
//  monitor's history going while the panel is closed.
//
import Foundation

@MainActor
final class CPULoadMonitor {
    static let shared = CPULoadMonitor()

    /// 0...1 over all cores; 0 until there are two readings to compare.
    private(set) var load: Double = 0

    private let reader = SystemStatsReader()
    private var timer: Timer?
    private var observers: [ObjectIdentifier: (Double) -> Void] = [:]
    private static let interval: TimeInterval = 2

    /// The handler gets the current load at once, then each new reading.
    func observe(_ owner: AnyObject, handler: @escaping (Double) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
        handler(load)
        guard timer == nil else { return }
        _ = reader.sample()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopObserving(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        guard observers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Memory and network come with the reading at little cost, and go to
    /// the system monitor's history, so it opens with the last minute.
    private func tick() {
        let sample = reader.sample()
        SystemMonitorModel.shared.record(sample)
        guard let cpu = sample.cpu else { return }
        load = cpu
        for handler in observers.values { handler(cpu) }
    }
}
