//
//  MainThreadWatchdog.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Notices when the main thread stops answering and records where it is
//  stuck. A background queue sends the main thread a beat every half second;
//  once one goes unanswered for longer than `threshold`, the watchdog
//  briefly suspends the main thread, walks its frame pointers, resumes it,
//  and logs the symbols, then logs again how long the stall lasted. The
//  sandbox rules out running `sample` on ourselves, and a stall short of the
//  system's own hang reports leaves no other trace.
//
//  The log goes to the unified log (subsystem io.github.1zumiii.nekonotch,
//  category watchdog) and to Logs/MainThreadStalls.log in the app's
//  container.
//
import Foundation
import QuartzCore
import os

final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    private static let interval: TimeInterval = 0.5
    private static let threshold: TimeInterval = 1.5
    private static let maxFrames = 64

    private let queue = DispatchQueue(label: "io.github.1zumiii.nekonotch.watchdog", qos: .utility)
    private let logger = Logger(subsystem: "io.github.1zumiii.nekonotch", category: "watchdog")
    private var timer: DispatchSourceTimer?
    private var mainThread: thread_act_t = 0

    private var lock = os_unfair_lock()
    /// When the main thread last answered, and whether a beat is on its way.
    private var lastBeat: CFTimeInterval = 0
    private var beatPending = false
    /// The stall being reported, from when the main thread last answered.
    private var stallStart: CFTimeInterval?

    /// Room for the frames, made before the main thread is suspended: while
    /// it is, nothing here may allocate, in case it holds the allocator's lock.
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)

    /// Also gets every message, for the tests.
    var onWrite: ((String) -> Void)?

    private init() {}

    /// Call on the main thread.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        mainThread = mach_thread_self()
        lastBeat = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        let silence = now - lastBeat
        let pending = beatPending
        let reported = stallStart != nil
        if !pending { beatPending = true }
        os_unfair_lock_unlock(&lock)

        if !pending {
            DispatchQueue.main.async { [weak self] in self?.beat() }
        }
        if silence > Self.threshold && !reported {
            os_unfair_lock_lock(&lock)
            stallStart = lastBeat
            os_unfair_lock_unlock(&lock)
            report(silence: silence)
        }
    }

    private func beat() {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&lock)
        lastBeat = now
        beatPending = false
        let start = stallStart
        stallStart = nil
        os_unfair_lock_unlock(&lock)
        if let start {
            write(String(format: "Main thread answered again after %.1f s", now - start))
        }
    }

    private func report(silence: TimeInterval) {
        let count = captureMainThread()
        var lines = [String(format: "Main thread stalled for %.1f s so far:", silence)]
        for index in 0..<count {
            lines.append("  \(index) \(Self.symbol(for: frames[index]))")
        }
        if count == 0 { lines.append("  (no frames)") }
        write(lines.joined(separator: "\n"))
    }

    /// Suspends the main thread just long enough to read its registers and
    /// walk its frame pointers into `frames`; returns how many it found.
    private func captureMainThread() -> Int {
        #if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }

        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }

        var count = 0
        func add(_ address: UInt64) {
            guard count < Self.maxFrames else { return }
            frames[count] = UInt(Self.strip(address))
            count += 1
        }
        add(state.__pc)
        add(state.__lr)
        var framePointer = state.__fp
        var link: (UInt64, UInt64) = (0, 0)
        while framePointer != 0, framePointer % 8 == 0, count < Self.maxFrames {
            var size = vm_size_t(MemoryLayout.size(ofValue: link))
            let read = withUnsafeMutablePointer(to: &link) {
                vm_read_overwrite(mach_task_self_, vm_address_t(framePointer), size,
                                  vm_address_t(UInt(bitPattern: $0)), &size)
            }
            guard read == KERN_SUCCESS, link.1 != 0 else { break }
            add(link.1)
            // The stack grows down, so each caller's frame lies higher up.
            guard link.0 > framePointer else { break }
            framePointer = link.0
        }
        return count
        #else
        return 0
        #endif
    }

    /// System code signs its return addresses; the signature sits above the
    /// 47 bits an address uses.
    private static func strip(_ address: UInt64) -> UInt64 {
        address & 0x0000_7FFF_FFFF_FFFF
    }

    private static func symbol(for address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        guard let name = info.dli_sname, let start = info.dli_saddr else {
            return String(format: "%@ 0x%lx", image, address)
        }
        let symbol = demangle(name) ?? String(cString: name)
        let offset = address - UInt(bitPattern: start)
        return "\(image) \(symbol) + \(offset)"
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    /// The Swift runtime's own demangler, looked up rather than linked.
    private static let swiftDemangle: Demangle? = {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(address, to: Demangle.self)
    }()

    /// A Swift symbol as it reads in source; nil for one that isn't Swift.
    private static func demangle(_ name: UnsafePointer<CChar>) -> String? {
        guard let swiftDemangle, let result = swiftDemangle(name, strlen(name), nil, nil, 0) else { return nil }
        defer { free(result) }
        return String(cString: result)
    }

    private func write(_ message: String) {
        logger.error("\(message, privacy: .public)")
        onWrite?(message)
        // The tests share the app's container; keep their stalls out of its log.
        guard !isRunningTests else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8),
              let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("MainThreadStalls.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }
}
