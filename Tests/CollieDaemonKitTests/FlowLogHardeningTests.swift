import Testing
import Foundation
@testable import CollieDaemonKit

/// Fires once: the first of the work and the timeout resumes the continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var c: CheckedContinuation<Bool, Never>?
    init(_ c: CheckedContinuation<Bool, Never>) { self.c = c }
    func fire(_ v: Bool) { lock.lock(); let k = c; c = nil; lock.unlock(); k?.resume(returning: v) }
}

/// True when `work` returns before `seconds`; the timeout is a cancelable Task, cancelled once the work is done.
private func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) async -> Bool {
    var timer: Task<Void, Never>?
    let r = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        let once = Once(c)
        Task.detached { work(); once.fire(true) }
        timer = Task { try? await Task.sleep(for: .seconds(seconds)); once.fire(false) }
    }
    timer?.cancel()
    return r
}

/// b2 (findings 3, 5, 6 of rev-device-flows-d1-d7): the flow log never follows a symlink, never blocks on a FIFO, refuses
/// hard links and cuts long targets. Nested in DeviceCommandTests: its router tests drive the fake adb (process-wide env).
extension DeviceCommandTests {
    @Suite struct FlowLogHardeningTests {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flowhard-\(UUID().uuidString.prefix(8))")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var log: FlowActionLog { FlowActionLog(paddock: root.appendingPathComponent("p"), flag: root.appendingPathComponent("daemon/enabled")) }
        var victim: URL { root.appendingPathComponent("victim") }
        let tap = FlowAction(origin: "agent:M", action: "tap", target: "a")
        var fm: FileManager { .default }

        func on() throws -> FlowActionLog {
            try log.setEnabled(true)
            try fm.createDirectory(at: log.dir, withIntermediateDirectories: true)
            try Data("keep\n".utf8).write(to: victim)
            return log
        }
        func perms(_ u: URL) throws -> Int { try #require(fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) }

        @Test func symlinkAtActionsIsNotFollowed() throws {
            defer { try? fm.removeItem(at: root) }
            let l = try on()
            try fm.createSymbolicLink(at: l.file, withDestinationURL: victim)
            #expect(throws: (any Error).self) { try l.append(tap, now: t0) }
            #expect(try String(contentsOf: victim, encoding: .utf8) == "keep\n")
        }

        @Test func symlinkAtRotatedFileIsDroppedNotWritten() throws {
            defer { try? fm.removeItem(at: root) }
            var l = try on(); l.maxBytes = 1
            try fm.createSymbolicLink(at: l.dir.appendingPathComponent("actions.1.jsonl"), withDestinationURL: victim)
            try l.append(tap, now: t0)
            try l.append(tap, now: t0)   // rotates: the symlink moves to .2 and is dropped there
            try l.append(tap, now: t0)
            #expect(try String(contentsOf: victim, encoding: .utf8) == "keep\n")
            for n in ["actions.1.jsonl", "actions.2.jsonl"] {
                let a = try fm.attributesOfItem(atPath: l.dir.appendingPathComponent(n).path)
                #expect(a[.type] as? FileAttributeType == .typeRegular)
            }
        }

        @Test func symlinkedFolderIsRefused() throws {
            defer { try? fm.removeItem(at: root) }
            let l = try on()
            try fm.removeItem(at: l.dir)
            let elsewhere = root.appendingPathComponent("elsewhere")
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: l.dir, withDestinationURL: elsewhere)
            #expect(throws: (any Error).self) { try l.append(tap, now: t0) }
            #expect(try fm.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        }

        @Test func fifoDoesNotBlock() async throws {
            defer { try? fm.removeItem(at: root) }
            let l = try on()
            #expect(mkfifo(l.file.path, 0o600) == 0)
            let returned = await finishes(within: 10) { _ = try? l.append(FlowAction(origin: "panel", action: "tap"), now: Date(timeIntervalSince1970: 1_800_000_000)) }
            #expect(returned)
        }

        @Test func hardLinkIsRefused() throws {
            defer { try? fm.removeItem(at: root) }
            let l = try on()
            #expect(link(victim.path, l.file.path) == 0)
            #expect(throws: (any Error).self) { try l.append(tap, now: t0) }
            #expect(try String(contentsOf: victim, encoding: .utf8) == "keep\n")
        }

        @Test func newFilesAre0600AndFolder0700() throws {
            defer { try? fm.removeItem(at: root) }
            var l = log; l.maxBytes = 1
            try l.setEnabled(true)
            try l.append(tap, now: t0); try l.append(tap, now: t0)
            #expect(try perms(l.dir) == 0o700)
            #expect(try perms(l.file) == 0o600)
            #expect(try perms(l.dir.appendingPathComponent("actions.1.jsonl")) == 0o600)
            #expect(!fm.fileExists(atPath: l.dir.appendingPathComponent("enabled").path))
        }

        @Test func longTargetIsCut() throws {
            defer { try? fm.removeItem(at: root) }
            let l = try on()
            try l.append(FlowAction(origin: "panel", action: "tap", target: String(repeating: "x", count: 5000)), now: t0)
            let o = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: l.file)) as? [String: String])
            #expect(o["target"] == String(repeating: "x", count: FlowActionLog.targetCap))
        }

        /// An inflated kept file is never read (no unbounded memory): rotation only renames it, unfiltered.
        @Test func oversizedRotatedFileIsRenamedNotRead() throws {
            defer { try? fm.removeItem(at: root) }
            var l = try on(); l.maxBytes = 300
            let junk = Data(repeating: UInt8(ascii: "z"), count: l.readCap + 1)   // no valid line: a read would drop it all
            try junk.write(to: l.dir.appendingPathComponent("actions.1.jsonl"))
            try l.append(tap, now: t0)
            try l.rotate(now: t0)
            #expect(try Data(contentsOf: l.dir.appendingPathComponent("actions.2.jsonl")) == junk)
            #expect(fm.fileExists(atPath: l.dir.appendingPathComponent("actions.1.jsonl").path))
        }

        @Test func rotationKeepsFilesWhole() throws {
            defer { try? fm.removeItem(at: root) }
            var l = try on(); l.maxBytes = 300
            for i in 0..<12 { try l.append(FlowAction(origin: "panel", action: "tap", target: "n\(i)"), now: t0) }
            var targets: [String] = []
            for n in ["actions.2.jsonl", "actions.1.jsonl", "actions.jsonl"] {
                let text = try String(contentsOf: l.dir.appendingPathComponent(n), encoding: .utf8)
                #expect(text.hasSuffix("\n"))
                for line in text.split(separator: "\n") {
                    let o = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
                    targets.append(try #require(o["target"]))
                }
            }
            #expect(targets == (12 - targets.count..<12).map { "n\($0)" })
            #expect(!(try fm.contentsOfDirectory(atPath: l.dir.path)).contains { $0.hasSuffix(".tmp") })
        }
    }
}
