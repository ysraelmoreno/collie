import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

@Suite(.serialized) struct AttentionTests {
    @Test func detectsClaudeTrustPrompt() {
        var d = AttentionDetector(preset: .claude)
        // real prompt, ANSI already stripped, split mid-sentence across two feeds
        #expect(d.feed(" Do you trust the files in th") == nil)
        #expect(d.feed("is folder?\n ❯ 1. Yes, proceed\n") != nil)
        var sh = AttentionDetector(preset: .shell)
        #expect(sh.feed("Do you trust the files in this folder?") == nil)
    }

    @Test func detectsGenericYesNo() {
        for s in ["Proceed? (Y/n)", "Overwrite [y/N] ", "Press Enter to continue"] {
            var d = AttentionDetector(preset: .shell)
            #expect(d.feed(s) != nil, "\(s)")
        }
    }

    @Test func noFalsePositiveOnNormalOutput() {
        var d = AttentionDetector(preset: .claude)
        for i in 0..<100 { #expect(d.feed("2026-10-19 INFO request \(i) handled in 12ms status=200\n") == nil) }
    }

    /// A prompt printed before the hub tracks the terminal (the launch awaits persist etc. in between; a loaded
    /// machine widens that gap) must still raise attention: it used to be read but never scanned.
    @Test func promptPrintedBeforeTrackIsSeen() async throws {
        let hub = StreamHub(asks: AskCoordinator(idleQuietSeconds: 2))
        let sb = ScrollbackBuffer(spillURL: nil)
        let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", "printf 'Go? (y/n) '; exec sleep 30"], cwd: "/tmp"),
                               scrollback: sb)
        defer { p.terminate() }
        #expect(await waitFor(20) { sb.text(since: 0).text.contains("(y/n)") })   // read before track
        let rec = TerminalRecord(id: UUID(), name: "A", preset: .custom, command: nil, cwd: "/tmp", isShepherd: false)
        await hub.track(rec, process: p, scrollback: sb)
        #expect(await waitFor(20) { await hub.currentBadges[rec.id] == .attention })
    }

    @Test func inputClearsAttentionBadge() async throws {
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let s = try await spawn(d, p, "A", preset: "custom", command: "printf 'Continue? (y/n) '; exec cat")
            let id = try #require(UUID(uuidString: s.id))
            var reason: String?, badges: [StatusBadge] = []
            while reason == nil || badges.last != .attention {
                guard case .event(let e)? = try await ev.next(timeoutSeconds: 30) else { break }
                if case .attention(id, let r) = e { reason = r }
                if case .status(id, let b) = e { badges.append(b) }
            }
            #expect(reason == "(y/n)")
            #expect(badges.last == .attention, "\(badges)")
            let a = try await StreamClient.open(Request(id: "a", token: d.adminToken, command: "ui.attach",
                                                        args: ["terminal": .string(s.id)]), path: p.socket)
            defer { a.close() }
            try await a.send(.in(Data("y\n".utf8)))
            var after: StatusBadge?
            while after == nil || after == .attention {
                guard case .event(let e)? = try await ev.next(timeoutSeconds: 30) else { break }
                if case .status(id, let b) = e { after = b }
            }
            #expect(after != nil && after != .attention, "\(String(describing: after))")
            #expect(await d.badge(id) != .attention)
        }
    }

    /// A TUI redraws its prompt after each keypress: nothing is raised inside the input's window (the redraw is held),
    /// and exactly once after it (the hub's scan and the tracker's both see it; the badge reports it once).
    @Test func redrawAfterInputRaisesOnceAfterTheWindow() async throws {
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            // prints the prompt again whenever a line arrives
            let s = try await spawn(d, p, "A", preset: "custom", command: "printf 'Go? (y/n) '; while read l; do printf 'Go? (y/n) '; done")
            let id = try #require(UUID(uuidString: s.id))
            var raised: [ContinuousClock.Instant] = []
            func drain(_ seconds: Double, until: () -> Bool = { false }) async throws {
                let end = Date().addingTimeInterval(seconds)
                while !until(), case .event(let e)? = try? await ev.next(timeoutSeconds: max(end.timeIntervalSinceNow, 0.01)) {
                    if case .attention(id, _) = e { raised.append(.now) }
                }
            }
            try await drain(10) { raised.count == 1 }
            #expect(raised.count == 1)
            let a = try await StreamClient.open(Request(id: "a", token: d.adminToken, command: "ui.attach",
                                                        args: ["terminal": .string(s.id)]), path: p.socket)
            defer { a.close() }
            let sent = ContinuousClock.now
            try await a.send(.in(Data("x\n".utf8)))
            try await drain(10) { raised.count == 2 }
            #expect(raised.count == 2)
            if raised.count == 2 { #expect(raised[1] - sent >= Fanout.inputQuiet, "raised inside the window") }
            // both sources are done once the tracker lists it again; after that the held badge admits nothing more
            #expect(await waitFor(10) { await d.router.asks.hasPendingApproval(id) })
            try await drain(0.3)   // negative check
            #expect(raised.count == 2)
        }
    }

    /// The badge is held past the working window (no input), and a new ask releases it.
    @Test func attentionHeldUntilAsk() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "custom", command: "echo T=$COLLIE_TOKEN; printf 'Go? (y/n) '; exec cat")
            let bid = try #require(UUID(uuidString: b.id))
            #expect(await waitFor(10) { await d.badge(bid) == .attention })
            try await Task.sleep(for: .seconds(3.5))   // > workingWindow (2 s) + several ticks
            #expect(await d.badge(bid) == .attention)
            let tokA = try await tokenOf(d, a.id)
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash",
                                              args: ["a": .string("A"), "b": .string("B")])).ok)
            let asking = Task { try await send(p, Request(id: "q", terminalId: a.id, token: tokA, command: "ask",
                                                          args: ["target": .string("B"), "prompt": .string("hi"), "timeout": .number(5)])) }
            #expect(await waitFor(5) { await d.badge(bid) != .attention })
            _ = try? await asking.value
        }
    }

    /// An ask releases the badge; a later prompt in the same terminal raises attention again.
    @Test func promptAfterAskReRaises() async throws {
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let a = try await spawn(d, p, "A")
            let b = try await spawn(d, p, "B", preset: "custom",
                                    command: "echo T=$COLLIE_TOKEN; printf 'Go? (y/n) '; read l; sleep 3; printf 'Again? (y/n) '; exec cat")
            let bid = try #require(UUID(uuidString: b.id))
            let tokA = try await tokenOf(d, a.id)
            #expect(await waitFor(10) { await d.badge(bid) == .attention })
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash",
                                              args: ["a": .string("A"), "b": .string("B")])).ok)
            let asking = Task { try await send(p, Request(id: "q", terminalId: a.id, token: tokA, command: "ask",
                                                          args: ["target": .string("B"), "prompt": .string("hi"), "timeout": .number(15)])) }
            var raised = 0
            let end = Date().addingTimeInterval(20)
            while raised < 2, case .event(let e)? = try? await ev.next(timeoutSeconds: max(end.timeIntervalSinceNow, 0.01)) {
                if case .attention(bid, _) = e { raised += 1 }
            }
            #expect(raised == 2)
            _ = try? await asking.value
        }
    }
}
