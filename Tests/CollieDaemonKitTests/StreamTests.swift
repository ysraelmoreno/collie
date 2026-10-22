import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func attach(_ d: Daemon, _ p: Paths, _ id: String) async throws -> StreamClient {
    try await StreamClient.open(Request(id: "a", token: d.adminToken, command: "ui.attach",
                                        args: ["terminal": .string(id)]), path: p.socket)
}
private let collieBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie").path
/// Pasted lines. Complete lines matter: a canonical-mode tty drops a partial line past its queue (no stall).
private func pasteLines(_ n: Int) -> Data { Data((String(repeating: "a", count: 63) + "\n").utf8).repeated(n / 64) }
private extension Data { func repeated(_ k: Int) -> Data { (0..<k).reduce(into: Data()) { d, _ in d.append(self) } } }
private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
/// Reads frames, appending `.out` text to `acc`, until `done` holds; returns the text.
private func readOut(_ c: StreamClient, _ seconds: Double = 30, after acc: String = "", until done: (String) -> Bool) async throws -> String {
    var acc = acc
    let deadline = Date().addingTimeInterval(seconds)
    while !done(acc) {
        guard let f = try await c.next(timeoutSeconds: deadline.timeIntervalSinceNow) else { break }
        if case .out(let d) = f { acc += text(d) }
    }
    return acc
}
private func spawnWaiting(_ d: Daemon, _ p: Paths, _ name: String, command: String, for needle: String) async throws -> String {
    let s = try await spawn(d, p, name, preset: "custom", command: command)
    #expect(s.resp.ok, "\(s.resp)")
    #expect(await waitFor(10) { await d.scrollbackText(UUID(uuidString: s.id)!).contains(needle) })
    return s.id
}

@Suite(.serialized) struct StreamTests {
    @Test func attachReplaysThenStreams() async throws {
        try await withDaemon { d, p in
            let id = try await spawnWaiting(d, p, "A", command: "echo hello; exec /bin/sh", for: "hello")
            let c = try await attach(d, p, id); defer { c.close() }
            guard case .replay(let r, truncated: false)? = try await c.next(timeoutSeconds: 30) else { Issue.record("no replay"); return }
            #expect(text(r).contains("hello"))
            try await c.send(.in(Data("echo zz$((40+2))\r".utf8)))
            let out = try await readOut(c) { $0.contains("zz42") }
            #expect(out.contains("zz42"), "\(out)")
        }
    }

    /// Mark + subscribe are atomic: replay followed by live output is the exact byte sequence, no gap, no repeat.
    @Test func replayAndLiveNeitherLoseNorDuplicate() async throws {
        try await withDaemon { d, p in
            let id = try await spawnWaiting(d, p, "A", command: "i=0; while [ $i -lt 60000 ]; do i=$((i+1)); echo n$i; done; echo END",
                                            for: "n1")
            let c = try await attach(d, p, id); defer { c.close() }
            guard case .replay(let r, truncated: false)? = try await c.next(timeoutSeconds: 30) else { Issue.record("no replay"); return }
            var all = r
            while let f = try await c.next(timeoutSeconds: 30) {   // .exited follows the trailing output
                if case .out(let d) = f { all += d } else if case .exited = f { break }
            }
            #expect(all == (await d.scrollbackRaw(try #require(UUID(uuidString: id)))), "stream \(all.count) bytes")
            // the tty may emit "\r\r\n"; compare lines, not separators
            let nums = text(all).replacingOccurrences(of: "\r", with: "").split(separator: "\n").filter { $0.hasPrefix("n") }
                .compactMap { Int($0.dropFirst()) }
            #expect(nums.elementsEqual(1...60000), "count \(nums.count)")
        }
    }

    @Test func resizeFrameReachesPty() async throws {
        try await withDaemon { d, p in
            let id = try await spawnWaiting(d, p, "A", command: "echo up; exec /bin/sh", for: "up")
            let c = try await attach(d, p, id); defer { c.close() }
            try await c.send(.resize(cols: 100, rows: 30))
            try await c.send(.in(Data("stty size\r".utf8)))
            let out = try await readOut(c) { $0.contains("30 100") }
            #expect(out.contains("30 100"), "\(out)")
        }
    }

    @Test func eventsStreamReportsLifecycle() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "A")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let b = try await spawn(d, p, "B")
            let bid = try #require(UUID(uuidString: b.id))
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.connect",
                                              args: ["a": .string("A"), "b": .string("B")])).ok)
            #expect(try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill",
                                              args: ["target": .string("B")])).ok)
            var got: [WorkspaceEvent] = []
            while got.last.map({ if case .removed = $0 { false } else { true } }) ?? true {
                guard case .event(let e)? = try await ev.next(timeoutSeconds: 30) else { break }
                if case .status = e { continue }
                got.append(e)
            }
            guard got.count == 4, case .spawned(let rec) = got[0], case .connected(let cn) = got[1],
                  case .disconnected(let dc) = got[2] else { Issue.record("\(got)"); return }
            #expect(rec.id == bid && rec.name == "B")
            #expect(cn.b == bid && dc == cn)
            #expect(got[3] == .removed(bid))
        }
    }

    @Test func statusBadgesEmittedOnChange() async throws {
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let b = try await spawn(d, p, "B", preset: "custom", command: "echo hi; sleep 3.5; exit 4")
            let bid = try #require(UUID(uuidString: b.id))
            var badges: [StatusBadge] = [], exited: Int32?
            while badges.last != .stopped || exited == nil {
                guard case .event(let e)? = try await ev.next(timeoutSeconds: 30) else { break }
                if case .status(bid, let s) = e { badges.append(s) }
                if case .exited(bid, let code) = e { exited = code }
            }
            #expect(badges == [.working, .idle, .stopped], "\(badges)")
            #expect(exited == 4)
        }
    }

    @Test func slowReaderIsCutNotBuffered() async throws {
        try await withDaemon { d, p in
            let id = try await spawnWaiting(d, p, "A", command: "echo up; exec /bin/sh", for: "up")
            let u = try #require(UUID(uuidString: id))
            let c = try await attach(d, p, id); defer { c.close() }
            // never read while the terminal prints 10 MiB (well past 4 MiB queue + socket buffers)
            try await c.send(.in(Data("head -c 10485760 /dev/zero | tr '\\0' a\r".utf8)))
            #expect(await waitFor(60) { await d.scrollbackTotalBytes(u) >= 10 * 1_048_576 })
            let peak = d.streamQueuePeakBytes
            #expect(peak > 0 && peak <= 4 * 1_048_576, "peak \(peak)")
            var sawOverflow = false
            while let f = try await c.next(timeoutSeconds: 30) {
                if case .overflow = f { sawOverflow = true; break }
            }
            #expect(sawOverflow)
            #expect(try await c.next(timeoutSeconds: 30) == nil)   // closed after the overflow
        }
    }

    @Test func clientCloseDropsSubscription() async throws {
        try await withDaemon { d, p in
            let id = try await spawnWaiting(d, p, "A", command: "echo up; exec /bin/sh", for: "up")
            let a = try await attach(d, p, id)
            let e = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            #expect(await waitFor(5) { await d.streamCount() == 2 })
            a.close(); e.close()
            #expect(await waitFor(5) { await d.streamCount() == 0 })
        }
    }

    /// The terminal never reads its input: the daemon stops reading the client instead of buffering it all,
    /// then reports the lost input (stalled PTY write) by cutting the stream.
    /// The stall deadline is raised so the tty never cuts the stream: only the 4 MiB queue bound limits memory.
    @Test func inputBackpressureBoundsMemory() async throws {
        try await withDaemon(configure: { $0.writeStall = .seconds(60) }) { d, p in
            let s = try await spawn(d, p, "A", preset: "custom", command: "sleep 30")
            let c = try await attach(d, p, s.id); defer { c.close() }
            let frame = pasteLines(64 * 1024)
            let writer = Task {
                for _ in 0..<320 { try await c.send(.in(frame), timeoutSeconds: 30) }   // 20 MiB
            }
            let high = 4 * 1_048_576
            #expect(await waitFor(30) { d.streamInputPeakBytes > high })
            let peak = d.streamInputPeakBytes
            #expect(peak <= high + frame.count * 2, "peak \(peak)")
            #expect(try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("A")])).ok)
            while try await c.next(timeoutSeconds: 30) != nil {}   // the kill closes the stream
            writer.cancel(); _ = await writer.result
            #expect(await waitFor(5) { await d.streamCount() == 0 })
        }
    }

    /// A client attaching after the process exited must still be tracked, so restart/kill closes its stream.
    @Test func attachAfterExitIsClosedByRestart() async throws {
        try await withDaemon { d, p in
            let s = try await spawn(d, p, "A", preset: "custom", command: "echo hi")
            let id = try #require(UUID(uuidString: s.id))
            #expect(await waitFor(10) { await d.process(id)?.isRunning == false })
            let old = try await attach(d, p, s.id); defer { old.close() }
            var frames: [StreamFrame] = []
            while frames.last.map({ if case .exited = $0 { return false } else { return true } }) ?? true {
                guard let f = try await old.next(timeoutSeconds: 30) else { break }
                frames.append(f)
            }
            guard case .exited? = frames.last else { Issue.record("no exited: \(frames)"); return }
            #expect(await d.streamCount() == 1)
            #expect(try await send(p, Request(id: "r", token: d.adminToken, command: "admin.restart", args: ["name": .string("A")])).ok)
            #expect(try await old.next(timeoutSeconds: 30) == nil)   // EOF: the old stream was closed
            let new = try await attach(d, p, s.id); defer { new.close() }
            guard case .replay? = try await new.next(timeoutSeconds: 30) else { Issue.record("no replay"); return }
        }
    }

    /// An ask prompt echoed back by the terminal ("(y/n)") is not the user's call: no attention while the ask is in flight.
    @Test func askPromptEchoDoesNotRaiseAttention() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "custom", command: "echo T=$COLLIE_TOKEN; exec cat")
            let bid = try #require(UUID(uuidString: b.id))
            let tokA = try await tokenOf(d, a.id)
            #expect(await waitFor(10) { await d.scrollbackText(bid).contains("T=") })
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.connect",
                                              args: ["a": .string("A"), "b": .string("B")])).ok)
            let asking = Task { try await send(p, Request(id: "q", terminalId: a.id, token: tokA, command: "ask",
                                                          args: ["target": .string("B"), "prompt": .string("go on? (y/n)"), "timeout": .number(4)])) }
            #expect(await waitFor(10) { await d.scrollbackText(bid).contains("(y/n)") })   // echoed by the tty
            #expect(await d.badge(bid) != .attention)
            try await Task.sleep(for: .milliseconds(600))
            #expect(await d.badge(bid) != .attention)
            _ = try? await asking.value
        }
    }

    @Test func inputWriteFailureClosesStream() async throws {
        try await withDaemon { d, p in
            let s = try await spawn(d, p, "A", preset: "custom", command: "sleep 30")
            let c = try await attach(d, p, s.id); defer { c.close() }
            try await c.send(.in(pasteLines(512 * 1024)))   // > the tty input queue
            var frames: [StreamFrame] = []
            while let f = try await c.next(timeoutSeconds: 15) { if case .replay = f {} else { frames.append(f) } }
            #expect(frames.last == .overflow, "\(frames)")
        }
    }

    @Test func uiAttachRefusedFromManagedTerminal() async throws {
        try await withDaemon { d, p in
            let b = try await spawn(d, p, "B")
            let cmd = "COLLIE_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)' '\(collieBin)' ui.attach \(b.id); echo RC=$?; exec sleep 300"
            let a = try await spawn(d, p, "A", preset: "custom", command: cmd)
            let id = try #require(UUID(uuidString: a.id))
            #expect(await waitFor(10) { await d.scrollbackText(id).contains("RC=") })
            let text = await d.scrollbackText(id)
            #expect(text.contains("admin commands are not allowed from managed terminals") && text.contains("RC=1"), "\(text)")
            #expect(await d.streamCount() == 0)
        }
    }

    @Test func killClosesAttachStream() async throws {
        try await withDaemon { d, p in
            let s = try await spawn(d, p, "A")
            let c = try await attach(d, p, s.id); defer { c.close() }
            #expect(try await send(p, Request(id: "k", token: d.adminToken, command: "admin.kill", args: ["target": .string("A")])).ok)
            let start = ContinuousClock.now
            while try await c.next(timeoutSeconds: 30) != nil {}
            #expect(ContinuousClock.now - start < .seconds(20))   // closed by the kill, not ended by the 30 s read timeout
        }
    }

    @Test func attachRequiresAdminToken() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, a.id)
            for cmd in ["ui.attach", "ui.events"] {
                let e = await #expect(throws: ProtocolError.self) {
                    _ = try await StreamClient.open(Request(id: "a", terminalId: a.id, token: tok, command: cmd,
                                                            args: ["terminal": .string(a.id)]), path: p.socket)
                }
                #expect(e?.code == .unauthorized)
            }
        }
    }

    @Test func exitedFrameOnProcessExit() async throws {
        try await withDaemon { d, p in
            let s = try await spawn(d, p, "A", preset: "custom", command: "echo bye; exit 3")
            let c = try await attach(d, p, s.id); defer { c.close() }
            var code: Int32?
            while code == nil, let f = try await c.next(timeoutSeconds: 30) {
                if case .exited(let x) = f { code = x }
            }
            #expect(code == 3)
        }
    }

    @Test func framesRoundTrip() throws {
        let frames: [StreamFrame] = [.out(Data([0, 1, 255])), .replay(Data("x".utf8), truncated: true), .in(Data("y".utf8)),
                                     .resize(cols: 80, rows: 24), .exited(code: -1), .overflow,
                                     .event(.status(UUID(), .working)), .event(.attention(UUID(), reason: "r")),
                                     .event(.connected(Connection(a: UUID(), b: UUID()))),
                                     .call(id: "c1", panel: UUID(), command: "browser.navigate", args: ["url": .string("u")], timeoutSeconds: 30),
                                     .reply(id: "c1", result: .object(["a": .number(1)]), error: nil),
                                     .reply(id: "c2", result: nil, error: ProtocolError(code: .timeout, message: "t")),
                                     .emit(panel: UUID(), name: "browser.loaded", payload: .null), .replaced]
        for f in frames {
            let line = try JSONEncoder().encode(f)
            #expect(try JSONDecoder().decode(StreamFrame.self, from: line) == f)
            #expect(!line.contains(10))
        }
        #expect(String(decoding: try JSONEncoder().encode(StreamFrame.overflow), as: UTF8.self) == #"{"t":"overflow"}"#)
    }
}
