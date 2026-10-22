import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private let fakeMCP = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-figcraft-mcp.py")
private let realCLI = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("vendor/figcraft/bin/figcraft-cli")

private struct Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-mcp-\(UUID().uuidString)")
    var log: URL { dir.appendingPathComponent("calls.log") }
    var runDir: URL { dir.appendingPathComponent("run") }
    init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func client(_ env: [String: String] = [:], name: String = "agent-1") async throws -> MCPStdioClient {
        try await MCPStdioClient(executable: fakeMCP, args: [], env: env.merging(["COLLIE_FAKE_FIG_LOG": log.path]) { a, _ in a },
                                 runDir: runDir, name: name)
    }
    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
}

private func code(_ body: () async throws -> Void) async -> ProtocolError? {
    do { try await body(); return nil } catch { return error as? ProtocolError }
}

@Suite(.serialized) struct MCPStdioClientTests {
    @Test func initializeAndCall() async throws {
        let fx = Fixture()
        let c = try await fx.client()
        defer { c.close() }
        let peers = try await c.command("collab.peers", [:], timeout: .seconds(10))
        guard case .object(let o) = peers else { Issue.record("\(peers)"); return }
        #expect(o["status"] == .string("live") && o["readOnly"] == .bool(false))
        #expect(fx.calls.first == "initialize agent-1", "\(fx.calls)")
        #expect(fx.calls.contains("notifications/initialized"), "\(fx.calls)")
        #expect(fx.calls.last == "tools/call run_command collab.peers", "\(fx.calls)")
        let shot = try await c.call("screenshot", ["ids": .array([.string("1:2")])], timeout: .seconds(10))
        #expect(shot.images.count == 1 && shot.images[0].prefix(4) == Data([0x89, 0x50, 0x4e, 0x47]) && !shot.isError)
    }

    @Test func responsesMatchById() async throws {
        let fx = Fixture()
        let c = try await fx.client(["COLLIE_FAKE_FIG_NOISE": "1"])
        defer { c.close() }
        for _ in 0..<3 {
            let r = try await c.command("collab.join", [:], timeout: .seconds(10))
            #expect(r == .object(["status": .string("live"), "readOnly": .bool(false)]), "\(r)")
        }
        let n = try await c.call("get_node", ["id": .string("1:2"), "depth": .number(1)], timeout: .seconds(10))
        #expect(n.texts.count == 1 && n.texts[0].contains("\"1:2\""), "\(n.texts)")
    }

    @Test func toolErrorBecomesProtocolError() async throws {
        let fx = Fixture()
        let c = try await fx.client()
        defer { c.close() }
        let e = await code { _ = try await c.command("bad.thing", [:], timeout: .seconds(10)) }
        #expect(e?.code == .internal && e?.message.contains("unknown command `bad.thing`") == true, "\(String(describing: e))")
        let b = await code {
            _ = try await c.call("batch", ["commands": .array([.object(["command": .string("node.create")]),
                                                                .object(["command": .string("bad.x")])])], timeout: .seconds(10))
        }
        #expect(b?.message.contains("`bad.x`") == true, "\(String(describing: b))")
        // a JSON-RPC error without a message still answers the call (not its timeout)
        let rpc = await code { _ = try await c.command("rpcerr", [:], timeout: .seconds(10)) }
        #expect(rpc == ProtocolError(code: .internal, message: "design engine: error -32603"), "\(String(describing: rpc))")
        #expect(c.isAlive)
    }

    @Test func timeoutKillsNothingButFails() async throws {
        let fx = Fixture()
        let c = try await fx.client(["COLLIE_FAKE_FIG_SLEEP": "1"])
        defer { c.close() }
        let e = await code { _ = try await c.command("collab.peers", [:], timeout: .milliseconds(200)) }
        #expect(e?.code == .timeout, "\(String(describing: e))")
        #expect(c.isAlive)
        // the late answer to the first call arrives first and must be ignored
        let r = try await c.command("text.fonts", [:], timeout: .seconds(10))
        #expect(r == .array([.string("Inter")]), "\(r)")
    }

    @Test func processDeathIsUnavailable() async throws {
        let fx = Fixture()
        let c = try await fx.client()
        let e = await code { _ = try await c.command("die", [:], timeout: .seconds(10)) }
        #expect(e == ProtocolError(code: .unavailable, message: "design engine stopped"), "\(String(describing: e))")
        #expect(await waitFor(5) { !c.isAlive })
        let again = await code { _ = try await c.command("collab.peers", [:], timeout: .seconds(10)) }
        #expect(again?.code == .unavailable)
        let closed = try await fx.client()
        closed.close()
        #expect(!closed.isAlive)
        #expect(await code { _ = try await closed.command("collab.peers", [:], timeout: .seconds(10)) }?.code == .unavailable)
    }

    @Test func oversizedResponseRejected() async throws {
        let fx = Fixture()
        let c = try await fx.client()
        defer { c.close() }
        let e = await code { _ = try await c.command("big", [:], timeout: .seconds(20)) }
        #expect(e?.code == .internal && e?.message.contains("too large") == true, "\(String(describing: e))")
        // the rest of the oversized line is skipped; the next answer still parses
        #expect(try await c.command("text.fonts", [:], timeout: .seconds(10)) == .array([.string("Inter")]))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realCLI.path)))
    func realHeadlessEngine() async throws {
        let fx = Fixture()
        let c = try await MCPStdioClient(executable: realCLI, args: ["mcp"], env: ProcessInfo.processInfo.environment,
                                         runDir: fx.runDir, name: "collie-test")
        defer { c.close() }
        let fonts = try await c.command("text.fonts", ["family": .string("Inter")], timeout: .seconds(30))
        #expect(fonts != .null && fonts != .array([]), "\(fonts)")
    }
}
