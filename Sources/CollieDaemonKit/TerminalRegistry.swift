import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

public actor TerminalRegistry {
    private let spillDir: URL
    private let memoryCapBytes: Int
    private let runDir: URL
    private let writeStall: Duration
    private let cttyHelper: String?
    private var procs: [UUID: PTYProcess] = [:]
    private var buffers: [UUID: ScrollbackBuffer] = [:]

    public init(spillDir: URL, memoryCapBytes: Int, runDir: URL, writeStall: Duration = .seconds(2), cttyHelper: String? = nil) {
        self.spillDir = spillDir; self.memoryCapBytes = memoryCapBytes; self.runDir = runDir; self.writeStall = writeStall
        self.cttyHelper = cttyHelper
    }

    /// `sandbox`: the terminal's Seatbelt profile; it runs through `sandbox-exec` (via the helper, or directly
    /// without one), never unsandboxed.
    public func spawn(_ rec: TerminalRecord, launch: LaunchSpec, sandbox: URL? = nil) throws -> PTYProcess {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let sb = ScrollbackBuffer(memoryCapBytes: memoryCapBytes,
                                  spillURL: spillDir.appendingPathComponent("\(rec.id.uuidString)-\(ms).log"))
        do {
            // checked per spawn: an app update can replace Helpers/ under a running daemon
            let helper = cttyHelper.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            var spec = launch
            if let helper {
                spec = launch.throughControllingTerminal(helper)
                if let sandbox { spec.arguments = ["--sandbox", sandbox.path] + spec.arguments }
            } else if let sandbox {
                spec.executable = "/usr/bin/sandbox-exec"; spec.arguments = ["-f", sandbox.path, launch.executable] + launch.arguments
            }
            let p = try PTYProcess(spec: spec, scrollback: sb, writeStall: writeStall)
            do { try OrphanReaper.record(pid: p.pid, terminal: rec.id, in: runDir) } catch {
                p.terminate()
                throw ProtocolError(code: .internal, message: "cannot record terminal pid: \(error)")
            }
            procs[rec.id] = p; buffers[rec.id] = sb
            let id = rec.id, dir = runDir, pid = p.pid
            p.onExit = { _ in OrphanReaper.forget(terminal: id, in: dir, ifPid: pid) }
            return p
        } catch { sb.closeSpill(deleting: true); throw error }
    }
    public func process(_ id: UUID) -> PTYProcess? { procs[id] }
    public func scrollback(_ id: UUID) -> ScrollbackBuffer? { buffers[id] }
    /// Terminates (the process keeps itself alive until reaped) and forgets the terminal; deletes its spill.
    public func remove(_ id: UUID) {
        procs.removeValue(forKey: id)?.terminate()
        buffers.removeValue(forKey: id)?.closeSpill(deleting: true)
    }
    func livePids() -> Set<pid_t> { Set(procs.values.filter(\.isRunning).map(\.pid)) }
    var counts: (procs: Int, buffers: Int) { (procs.count, buffers.count) }
    /// SIGHUP everything, wait up to 2s, SIGKILL survivors and wait (up to 1s) for them to be reaped.
    public func killAll() async {
        let all = Array(procs.values)
        all.forEach { $0.terminate() }
        await waitExit(all, seconds: 2)
        for p in all where p.isRunning { Darwin.kill(-p.pid, SIGKILL); Darwin.kill(p.pid, SIGKILL) }
        await waitExit(all, seconds: 1)
    }

    private func waitExit(_ ps: [PTYProcess], seconds: Double) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ps.contains(where: { $0.isRunning }) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
