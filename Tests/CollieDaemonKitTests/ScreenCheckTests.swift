import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieScreen
@testable import CollieDaemonKit

/// DX backlog 2: `check --screen` returns the rendered screen, not the redraw stream.
private struct Term { var id: String; var token: String }

private func term(_ d: Daemon, _ p: Paths, _ name: String, command: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp")]
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id, echo: command == nil))
}

private func check(_ p: Paths, _ from: Term, _ target: String) async throws -> Response {
    try await send(p, Request(id: "c", terminalId: from.id, token: from.token, command: "check",
                              args: ["target": .string(target), "screen": .bool(true)]))
}

private func output(_ r: Response) -> String {
    if case .object(let o)? = r.result, case .string(let s)? = o["output"] { return s } else { return "<\(r)>" }
}

// a spinner redrawn in place, then a block erased by moving up and clearing to the end of the screen
private let redraws = #"echo T=$COLLIE_TOKEN; printf 'spin 1\r\033[Kspin 2\r\033[Kready\nold a\nold b\n\033[2A\033[Jfinal line\n'; exec sleep 999"#

@Suite(.serialized) struct ScreenCheckTests {
    @Test func screenShowsWhatIsDrawnNow() async throws {
        try await withDaemon(configure: { $0.screenRenderer = ScreenRenderer.render }) { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "B", command: redraws)
            #expect(try await send(p, Request(id: "l", token: d.adminToken, command: "admin.leash", args: ["a": "A", "b": "B"])).ok)
            #expect(await waitFor(10) { output(try! await check(p, a, "B")).contains("final line") })
            let screen = output(try await check(p, a, "B"))
            #expect(screen.contains("ready") && !screen.contains("spin") && !screen.contains("old"), "\(screen)")
            #expect(!screen.hasSuffix("\n") && !screen.contains("   \n"), "rows trimmed: \(screen)")
        }
    }

    @Test func screenWithoutARendererSaysSo() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A"), _ = try await term(d, p, "B")
            #expect(try await send(p, Request(id: "l", token: d.adminToken, command: "admin.leash", args: ["a": "A", "b": "B"])).ok)
            #expect(try await check(p, a, "B").error?.code == .unavailable)
        }
    }
}
