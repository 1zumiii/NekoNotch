//
//  ProcessEnergy.swift
//  BoringNotchXPCHelper
//
import Darwin
import Foundation

/// Energy each process has used since it started, as the kernel counts it,
/// summed per responsible process the way Activity Monitor does: a helper or
/// a command-line tool counts toward the app responsible for it. Here and not
/// in the app because the sandbox does not let the app read other processes.
enum ProcessEnergy {
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// Private, but what Activity Monitor uses to put a helper under its app.
    private static let responsiblePID: ResponsibleFunction? = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"
    ).map { unsafeBitCast($0, to: ResponsibleFunction.self) }

    /// Nanojoules per responsible process. Processes of other users (system
    /// daemons) can't be read and are left out.
    static func byResponsibleProcess() -> [pid_t: UInt64] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(max(count, 0))) where pid > 0 {
            var info = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard status == 0, info.ri_energy_nj > 0 else { continue }
            let owner = responsiblePID?(pid) ?? pid
            result[owner > 0 ? owner : pid, default: 0] += info.ri_energy_nj
        }
        return result
    }
}
