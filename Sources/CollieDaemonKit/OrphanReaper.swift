import Foundation
import Darwin

/// Pidfiles (`<runDir>/terminals/<id>.pid`) let a restarted daemon kill process groups orphaned by a crash.
/// Adoption is impossible (the PTY master died with the daemon), so they are killed, not reattached.
enum OrphanReaper {
    private static func file(_ id: UUID, _ runDir: URL) -> URL {
        runDir.appendingPathComponent("terminals/\(id.uuidString).pid")
    }

    static func record(pid: pid_t, terminal: UUID, in runDir: URL) throws {
        let dir = runDir.appendingPathComponent("terminals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try "\(pid)".write(to: file(terminal, runDir), atomically: true, encoding: .utf8)
    }

    /// `ifPid`: only remove when the file still names that pid (a replaced launch reuses the id).
    static func forget(terminal: UUID, in runDir: URL, ifPid: pid_t? = nil) {
        let f = file(terminal, runDir)
        if let ifPid, pidOf(f) != ifPid { return }
        try? FileManager.default.removeItem(at: f)
    }

    private static func pidOf(_ f: URL) -> pid_t? {
        (try? String(contentsOf: f, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func startTime(_ pid: pid_t) -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
    }

    /// Blocking (up to ~2 s): call off the cooperative pool. Returns the number of groups killed.
    static func reapAll(in runDir: URL) -> Int {
        let dir = runDir.appendingPathComponent("terminals")
        var victims: [pid_t] = []
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "pid" {
            defer { try? FileManager.default.removeItem(at: f) }
            guard let pid = pidOf(f), pid > 1 else { continue }
            if kill(pid, 0) == 0 || errno == EPERM {
                // leader alive: make sure the pid was not reused after the pidfile was written
                guard let started = startTime(pid),
                      let mtime = (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date,
                      started <= mtime else { continue }
            } else if kill(-pid, 0) != 0 { continue }   // leader gone: a live pgid can't be reused as a pid, so orphans are ours
            victims.append(pid)
        }
        victims.forEach { kill(-$0, SIGHUP) }
        let deadline = ContinuousClock.now + .seconds(2)
        while victims.contains(where: { kill(-$0, 0) == 0 }) && ContinuousClock.now < deadline { usleep(20_000) }
        victims.forEach { kill(-$0, SIGKILL) }   // ESRCH for the already-gone ones
        return victims.count
    }
}
