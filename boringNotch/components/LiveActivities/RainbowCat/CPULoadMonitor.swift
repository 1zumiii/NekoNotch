//
//  CPULoadMonitor.swift
//  boringNotch
//
//  Total CPU load for the rainbow cat's pace, read every two seconds and
//  only while a cat is on screen. The same reading keeps the system
//  monitor's history going while the panel is closed.
//
import Defaults
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
    /// A load the settings' test buttons show for a few seconds instead of
    /// the real one; the system monitor's history still gets real readings.
    private var simulated: Double?
    private var simulationEnd: Task<Void, Never>?

    /// The handler gets the current load at once, then each new reading.
    func observe(_ owner: AnyObject, handler: @escaping (Double) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
        handler(simulated ?? load)
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
        broadcast()
    }

    /// Shows `load` to every cat and sky for `seconds`, then the real load
    /// again; nil ends a simulation at once.
    func simulate(_ load: Double?, for seconds: TimeInterval) {
        simulationEnd?.cancel()
        simulated = load
        broadcast()
        guard load != nil else { return }
        simulationEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.simulated = nil
            self.broadcast()
        }
    }

    /// How far the cat and the sky are from their resting pace towards their
    /// fastest, 0...1. With warp on they reach it at the warp threshold, as
    /// past that the sky is in warp; with warp off, at full load.
    nonisolated static func pace(for load: Double) -> Double {
        let load = min(max(load, 0), 1)
        guard Defaults[.rainbowCatWarp] else { return load }
        return min(load / max(Defaults[.rainbowCatWarpThreshold], 0.05), 1)
    }

    private func broadcast() {
        let value = simulated ?? load
        for handler in observers.values { handler(value) }
    }
}
