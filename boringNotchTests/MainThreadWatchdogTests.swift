//
//  MainThreadWatchdogTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

final class MainThreadWatchdogTests: XCTestCase {
    /// A main thread held up for two seconds is reported with where it was
    /// stuck, and again once it answers.
    func testReportsWhereTheMainThreadIsStuck() {
        let watchdog = MainThreadWatchdog.shared
        var messages: [String] = []
        let lock = NSLock()
        watchdog.onWrite = { message in
            lock.lock()
            messages.append(message)
            lock.unlock()
        }
        defer { watchdog.onWrite = nil }
        watchdog.start()

        Thread.sleep(forTimeInterval: 2.2)
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        lock.lock()
        let all = messages.joined(separator: "\n")
        lock.unlock()
        XCTAssertTrue(all.contains("Main thread stalled for"), all)
        XCTAssertTrue(all.contains("testReportsWhereTheMainThreadIsStuck"), all)
        XCTAssertTrue(all.contains("sleep"), all)
        XCTAssertTrue(all.contains("Main thread answered again after"), all)
    }
}
