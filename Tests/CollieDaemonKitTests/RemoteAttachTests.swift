import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 6 (spec §3.5): terminal.attach streams a terminal's output (replay, out, exited) to a phone.
private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }
private func bytes(_ v: JSONValue?) -> Data { Data(base64Encoded: str(v)) ?? Data() }

/// Frames of `sub` until `stop` says so (or nothing for `timeout`): everything the phone got for it, in order.
private func frames(_ ph: RemotePhone, _ sub: String, timeout: Double = 10, until stop: ([String: JSONValue]) -> Bool) async -> [[String: JSONValue]] {
    var out: [[String: JSONValue]] = []
    while let o = await ph.next(timeout: timeout) {
        guard o["sub"] == .string(sub) else { continue }
        out.append(o)
        if stop(o) { break }
    }
    return out
}
private func text(_ fs: [[String: JSONValue]]) -> String {
    String(decoding: fs.filter { $0["t"] == "replay" || $0["t"] == "out" }.reduce(Data()) { $0 + bytes($1["d"]) }, as: UTF8.self)
}

@Suite(.serialized) struct RemoteAttachTests {
    private func attach(_ ph: RemotePhone, _ id: String, _ extra: [String: JSONValue] = [:]) async throws -> Response {
        try await ph.call("terminal.attach", ["terminal": .string(id)].merging(extra) { a, _ in a })
    }

    @Test func replayThenOutputThenExit() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _) = try await spawn(d, p, "T", preset: "custom", command: "echo BEFORE; sleep 2; printf 'AFTER\\033[1m'; exit 3")
            try await Task.sleep(for: .milliseconds(500))
            let r = try await attach(ph, id)
            let sub = str(obj(r.result)["sub"])
            #expect(r.ok && sub.hasPrefix("t-"), "\(r)")
            let fs = await frames(ph, sub) { $0["t"] == "exited" }
            #expect(fs.first?["t"] == "replay" && fs.first?["truncated"] == .bool(false), "\(fs)")
            let replay = String(decoding: bytes(fs.first?["d"]), as: UTF8.self)
            #expect(replay.contains("BEFORE"), "\(replay)")
            #expect(text(fs).contains("AFTER\u{1B}[1m"), "raw bytes, ANSI included: \(text(fs))")
            #expect(fs.last?["t"] == "exited" && fs.last?["code"] == .number(3), "\(String(describing: fs.last))")
            #expect(fs.filter { $0["t"] == "replay" }.count == 1)
        }
    }

    @Test func replayIsCutToReplayBytes() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _) = try await spawn(d, p, "T", preset: "custom", command: "for i in $(seq 1 200); do echo line$i; done; sleep 30")
            try await Task.sleep(for: .milliseconds(800))
            let sub = str(obj(try await attach(ph, id, ["replayBytes": 16]).result)["sub"])
            let fs = await frames(ph, sub) { $0["t"] == "replay" }
            let rep = bytes(fs.last?["d"])
            #expect(fs.last?["truncated"] == .bool(true) && rep.count <= 16 && String(decoding: rep, as: UTF8.self).contains("line200"), "\(fs)")
            #expect(!(try await attach(ph, id, ["replayBytes": -1]).ok))
        }
    }

    @Test func outputIsCoalescedNothingDropped() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _) = try await spawn(d, p, "T", preset: "custom",
                                          command: "sleep 1.5; for i in $(seq 1 3000); do echo line$i; sleep 0.0005; done; echo END; sleep 30")
            let sub = str(obj(try await attach(ph, id).result)["sub"])
            var stamps: [Date] = []
            var all: [[String: JSONValue]] = []
            while let o = await ph.next(timeout: 15) {
                guard o["sub"] == .string(sub) else { continue }
                all.append(o)
                if o["t"] == "out" { stamps.append(Date()) }
                if text(all).contains("END") { break }
            }
            let got = text(all)
            #expect((1...3000).allSatisfy { got.contains("line\($0)\r\n") }, "lost bytes")   // the PTY writes \r\n
            // ≤ 10 frames/s: never more than 11 out frames inside one second (arrival jitter)
            let worst = stamps.indices.map { i in stamps[i...].prefix { $0.timeIntervalSince(stamps[i]) < 1 }.count }.max() ?? 0
            #expect(worst <= 11, "\(worst) frames in a second, \(stamps.count) total")
        }
    }

    @Test func errorsAndLimits() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            #expect(try await attach(ph, UUID().uuidString).error?.code == .notFound)
            #expect(try await ph.call("terminal.attach").error?.code == .invalidArgs)
            let (short, _) = try await spawn(d, p, "Short", preset: "custom", command: "true")
            var code: ErrorCode?
            for _ in 0..<50 { code = try await attach(ph, short).error?.code; if code == .notRunning { break }; try await Task.sleep(for: .milliseconds(100)) }
            #expect(code == .notRunning)
            let (id, _) = try await spawn(d, p, "Long", preset: "custom", command: "sleep 30")
            for _ in 0..<4 { #expect(try await attach(ph, id).ok) }
            #expect(try await attach(ph, id).error?.code == .tooMany)
            #expect(try await ph.call("terminal.detach", ["sub": "t-404"]).error?.code == .notFound)
        }
    }

    @Test func detachStopsOutputAndInputIsIgnored() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _) = try await spawn(d, p, "T", preset: "custom", command: "cat; sleep 30")
            let sub = str(obj(try await attach(ph, id).result)["sub"])
            // the phone's keyboard and size are not taken: no echo, the socket stays
            try await ph.task.send(.string(#"{"t":"in","sub":"\#(sub)","d":"\#(Data("TYPED\n".utf8).base64EncodedString())"}"#))
            try await ph.task.send(.string(#"{"t":"resize","sub":"\#(sub)","cols":10,"rows":5}"#))
            let fs = await frames(ph, sub, timeout: 1.5) { _ in false }
            #expect(!text(fs).contains("TYPED"), "\(fs)")
            #expect(try await ph.call("terminal.detach", ["sub": .string(sub)]).ok)
            #expect(try await ph.call("terminal.detach", ["sub": .string(sub)]).error?.code == .notFound)
            // a detached sub frees its slot
            for _ in 0..<4 { #expect(try await attach(ph, id).ok) }
        }
    }

    @Test func overflowCutsTheSub() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true; $0.remoteEventQueueBytes = 1 }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let (id, _) = try await spawn(d, p, "T", preset: "custom", command: "sleep 1.5; echo burst; sleep 30")
            let sub = str(obj(try await attach(ph, id).result)["sub"])
            let fs = await frames(ph, sub) { $0["t"] == "overflow" }
            #expect(fs.last?["t"] == "overflow", "\(fs)")
            #expect(try await ph.call("workspace.snapshot").ok)   // the session stays
            #expect(try await ph.call("terminal.detach", ["sub": .string(sub)]).error?.code == .notFound)
        }
    }
}
