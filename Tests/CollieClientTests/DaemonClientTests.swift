import Testing
import Foundation
import Darwin
import CollieCore
import Synchronization
import CollieProtocol
import CollieDaemonKit   // UnixSocketServer: a fake, stalling daemon
@testable import CollieClient

// <pkg>/Tests/CollieClientTests/this.swift -> <pkg>/.build/debug/collied (swift test builds all products)
let colliedURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collied")

/// Waits for a positive condition; `seconds` is floored at 20 s (free when it passes, absorbs a loaded machine).
@MainActor func poll(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(max(seconds, 20))
    while ContinuousClock.now < deadline { if cond() { return true }; try? await Task.sleep(for: .milliseconds(25)) }
    return cond()
}

/// A real collied child process on a short /tmp/collie-* root. `cleanup()` kills daemons, terminals and the root.
@MainActor final class Collied {
    let root = URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")
    var paths: Paths { Paths(root: root) }
    var pidFile: URL { root.appendingPathComponent("pids") }   // terminals append their pid here
    private var procs: [Process] = []

    func start() async throws {
        let old = try? String(contentsOf: paths.adminTokenFile, encoding: .utf8)
        let p = Process(); p.executableURL = colliedURL; p.arguments = ["--root", root.path, "--no-terminal-sandbox"]
        p.environment = ProcessInfo.processInfo.environment.merging(["COLLIE_USER_ENV": "off"]) { $1 }
        try p.run(); procs.append(p)
        try #require(await poll(5) {
            (try? String(contentsOf: paths.adminTokenFile, encoding: .utf8)).map { $0 != old } ?? false
                && FileManager.default.fileExists(atPath: paths.socket.path)
        })
    }
    func kill9() { for p in procs where p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() } }
    func cleanup() {
        for p in procs where p.isRunning { kill(p.processIdentifier, SIGTERM); p.waitUntilExit() }
        for l in ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").split(separator: "\n") {
            if let n = pid_t(l) { kill(-n, SIGKILL); kill(n, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: root)
    }
    /// A custom command that records its pid first (so cleanup can kill orphans of a SIGKILLed daemon).
    func cmd(_ s: String) -> String { "echo $$ >> '\(pidFile.path)'; \(s)" }
}

@MainActor @Suite(.serialized) struct DaemonClientTests {
    @Test func clientMirrorsWorkspace() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected })
        let a = try await c.spawn(name: "A", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)
        _ = try await c.spawn(name: "B", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)
        try await c.leash("A", "B")
        #expect(await poll(2) { c.terminals.count == 2 && c.connections.count == 1 })
        #expect(c.terminals.first?.id == a)
        try await c.unleash("A", "B")
        try await c.kill("B")
        #expect(await poll(2) { c.terminals.map(\.name) == ["A"] && c.connections.isEmpty })
    }

    @Test func clientReconnectsAfterDaemonRestart() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected })
        let a = try await c.spawn(name: "A", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)
        #expect(await poll(2) { c.terminals.count == 1 })

        d.kill9()
        #expect(await poll(2) { if case .disconnected = c.state { true } else { false } })
        try await d.start()   // rotates admin.token; the client re-reads it
        #expect(await poll(5) { c.state == .connected && c.terminals.map(\.id) == [a] && c.badges[a] == .stopped },
                "\(c.state) \(c.terminals) \(c.badges)")
        try await c.restart("A")
        #expect(await poll(3) { c.badges[a] != nil && c.badges[a] != .stopped }, "\(c.badges)")
    }

    @Test func streamReattachesAfterOverflow() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected })
        let go = d.root.appendingPathComponent("go"), done = d.root.appendingPathComponent("done")
        // waits for "go", prints 10 MiB (well past the daemon's 4 MiB send queue + socket buffers), then idles
        let id = try await c.spawn(name: "Y", preset: .custom, command: d.cmd(
            "while [ ! -f '\(go.path)' ]; do sleep 0.05; done; head -c 10485760 /dev/zero | tr '\\0' a; " +
            "touch '\(done.path)'; echo tail-marker; exec sleep 300"), cwd: "/tmp", shepherd: false)
        let s = c.attach(id); defer { s.close() }
        let watchdog = Task { try? await Task.sleep(for: .seconds(60)); s.close() }   // never hang the suite
        defer { watchdog.cancel() }
        var it = s.frames.makeAsyncIterator()
        guard case .replay? = await it.next() else { Issue.record("first frame is not a replay"); return }
        // client paused (not iterating) while the terminal prints: the daemon cuts the stream
        FileManager.default.createFile(atPath: go.path, contents: nil)
        #expect(await poll(60) { FileManager.default.fileExists(atPath: done.path) })
        var replays = 0, tail = Data()
        while let f = await it.next() {
            switch f {
            case .replay(let data, _): replays += 1; tail = data.suffix(4096)
            case .out(let data): tail.append(data)
            default: break
            }
            if replays > 0, String(decoding: tail, as: UTF8.self).contains("tail-marker") { break }
        }
        #expect(replays == 1)
        #expect(String(decoding: tail, as: UTF8.self).contains("tail-marker"))
        s.close(); s.close()   // idempotent
        #expect(await it.next() == nil)
    }

    /// stop() while `ui.events` is still being opened: the late session must not publish `.connected` or keep a stream.
    @Test func stopDuringConnectLeavesDisconnected() async throws {
        let root = URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"), paths = Paths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "fake-token".write(to: paths.adminTokenFile, atomically: true, encoding: .utf8)
        let gate = Mutex(false), asked = Mutex(false)
        let empty = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            WorkspaceSnapshot(terminals: [], connections: [], badges: [:])))
        let server = UnixSocketServer(path: paths.socket) { req in
            if req.command == "ui.events" {   // stalls until the gate opens, then accepts (and closes)
                asked.withLock { $0 = true }
                while !gate.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            }
            return Response(id: req.id, ok: true, result: req.command == "ui.snapshot" ? empty : .object([:]))
        }
        try server.start(); defer { server.stop() }

        let c = DaemonClient(paths: paths); c.start()
        #expect(await poll(5) { asked.withLock { $0 } })
        c.stop()
        gate.withLock { $0 = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            #expect(c.state == .disconnected(reason: "stopped"))
            if c.state != .disconnected(reason: "stopped") { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(c.openEventStreams == 0)
    }

    @Test func quickRestartKeepsOneEventsSubscription() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths)
        c.start(); c.stop(); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected && c.openEventStreams == 1 })
        try await Task.sleep(for: .milliseconds(500))   // let any stale session finish
        #expect(c.openEventStreams == 1 && c.state == .connected)
        c.stop()
        #expect(await poll(2) { c.openEventStreams == 0 })
    }

    @Test func inputDuringReattachIsDelivered() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        let id = try await c.spawn(name: "S", preset: .custom, command: d.cmd("echo up; exec /bin/sh"), cwd: "/tmp", shepherd: false)
        let s = c.attach(id); defer { s.close() }
        let watchdog = Task { try? await Task.sleep(for: .seconds(30)); s.close() }
        defer { watchdog.cancel() }
        var it = s.frames.makeAsyncIterator()
        guard case .replay? = await it.next() else { Issue.record("no replay"); return }
        s._simulateDrop()
        s.send(Data("echo got-$((40+2))\r".utf8))   // typed while the stream reattaches
        var replays = 0, text = ""
        while !text.contains("got-42"), let f = await it.next() {
            if case .replay(let data, _) = f { replays += 1; text = String(decoding: data, as: UTF8.self) }
            if case .out(let data) = f { text += String(decoding: data, as: UTF8.self) }
        }
        #expect(replays >= 1 && text.contains("got-42"), "\(replays) \(text)")
        #expect(s.droppedInputBytes == 0)
    }

    @Test func resizeResentAfterReattach() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        let id = try await c.spawn(name: "S", preset: .custom, command: d.cmd("echo up; exec /bin/sh"), cwd: "/tmp", shepherd: false)
        let s1 = c.attach(id), s2 = c.attach(id); defer { s1.close(); s2.close() }
        let watchdog = Task { try? await Task.sleep(for: .seconds(30)); s1.close(); s2.close() }
        defer { watchdog.cancel() }
        var i1 = s1.frames.makeAsyncIterator(), i2 = s2.frames.makeAsyncIterator()
        _ = await i1.next(); _ = await i2.next()
        s1.resize(cols: 100, rows: 30)
        try await Task.sleep(for: .milliseconds(300))   // past the debounce
        s2.resize(cols: 50, rows: 20)                  // another viewer changes the PTY size
        try await Task.sleep(for: .milliseconds(300))
        s2.send(Data("stty size\r".utf8))
        #expect(await readUntil(&i2, "20 50"))
        s1._simulateDrop()                             // s1 reattaches and re-sends its size
        var sawReplay = false
        while !sawReplay, let f = await i1.next() { if case .replay = f { sawReplay = true } }
        try await Task.sleep(for: .milliseconds(200))
        s1.send(Data("stty size\r".utf8))
        #expect(await readUntil(&i1, "30 100"))
    }

    @Test func resizeDebounceSendsLastSizeOnly() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        let script = d.root.appendingPathComponent("winch.sh")   // plain sh: prints the size on every SIGWINCH
        try "trap 'echo \"winch $(stty size)\"' WINCH\necho ready\nwhile :; do sleep 0.01; done\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let id = try await c.spawn(name: "W", preset: .custom, command: d.cmd("exec /bin/sh '\(script.path)'"),
                                   cwd: "/tmp", shepherd: false)
        let s = c.attach(id); defer { s.close() }
        let watchdog = Task { try? await Task.sleep(for: .seconds(30)); s.close() }
        defer { watchdog.cancel() }
        var it = s.frames.makeAsyncIterator()
        var text = ""
        while !text.contains("ready"), let f = await it.next() {
            if case .replay(let data, _) = f { text = String(decoding: data, as: UTF8.self) }
            if case .out(let data) = f { text += String(decoding: data, as: UTF8.self) }
        }
        // 40 ms apart: each lands inside the previous one's 100 ms window, but far enough apart that undebounced
        // resizes would reach the shell (trap runs within ~10 ms) as separate SIGWINCHes
        s.resize(cols: 81, rows: 21)
        try await Task.sleep(for: .milliseconds(40)); s.resize(cols: 82, rows: 22)
        try await Task.sleep(for: .milliseconds(40)); s.resize(cols: 83, rows: 23)
        text = ""
        while !text.contains("winch 23 83"), let f = await it.next() {
            if case .out(let data) = f { text += String(decoding: data, as: UTF8.self) }
        }
        try await Task.sleep(for: .milliseconds(300))   // any extra resize would show up as another winch line
        s._simulateDrop()   // a fresh replay holds the whole output: count the winch lines there
        var replay = ""
        while let f = await it.next() { if case .replay(let data, _) = f { replay = String(decoding: data, as: UTF8.self); break } }
        #expect(replay.components(separatedBy: "winch ").count - 1 == 1, "\(replay)")
        #expect(replay.contains("winch 23 83"))
    }
}

/// Reads `.out` frames until `needle` shows up (the caller's watchdog bounds it).
@MainActor private func readUntil(_ it: inout AsyncStream<StreamFrame>.Iterator, _ needle: String) async -> Bool {
    var text = ""
    while !text.contains(needle), let f = await it.next(isolation: MainActor.shared) {
        if case .out(let data) = f { text += String(decoding: data, as: UTF8.self) }
    }
    return text.contains(needle)
}
