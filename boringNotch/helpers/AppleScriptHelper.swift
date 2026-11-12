//
//  AppleScriptHelper.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import os

enum AppleScriptError: Error {
    case timedOut
}

final class AppleScriptHelper {
    /// Runs a script off the main thread. A target app that hangs never
    /// answers, so the caller gets `timedOut` after `timeout` seconds; the
    /// script itself finishes or fails in the background and its result is
    /// dropped. Whichever side finishes first resumes the continuation.
    @discardableResult
    class func execute(_ scriptText: String, timeout: TimeInterval = 5) async throws -> NSAppleEventDescriptor? {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let claim: @Sendable () -> Bool = {
            resumed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let script = NSAppleScript(source: scriptText)
                var error: NSDictionary?
                let descriptor = script?.executeAndReturnError(&error)
                guard claim() else { return }
                if let descriptor {
                    continuation.resume(returning: descriptor)
                } else if let error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard claim() else { return }
                continuation.resume(throwing: AppleScriptError.timedOut)
            }
        }
    }

    class func executeVoid(_ scriptText: String, timeout: TimeInterval = 5) async throws {
        _ = try await execute(scriptText, timeout: timeout)
    }
}
