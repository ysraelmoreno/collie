import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// DX backlog 15 (strict mode; the open mode keeps "any folder, no cards"): a summon outside the Shepherd's project asks
/// the user with an access card instead of a bare refusal, and goes through once the folder is released.
extension CommandRouter { func markSandboxedForTests(_ id: UUID) { sandboxKnown.insert(id) } }

@Suite(.serialized) struct SummonCwdTests {
    @Test func outsideTheProjectAsksForTheFolder() async throws {
        let repo = try await makeRepo()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("collie-out-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let out = SignedAppCheck.realPath(outside)
        try await withDaemon { d, p in
            let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: [
                "name": "M", "preset": "shell", "cwd": .string(repo.path), "shepherd": true]))
            guard case .object(let o)? = r.result, case .string(let mid)? = o["id"] else { Issue.record("\(r)"); return }
            await d.router.markSandboxedForTests(UUID(uuidString: mid)!)   // as a real sandboxed launch (no sandbox home in tests)
            func summon(_ tok: String) async throws -> Response {
                try await send(p, Request(id: "m", terminalId: mid, token: tok, command: "summon",
                                          args: ["name": "W", "preset": "shell", "cwd": .string(out)]), timeoutSeconds: 60)
            }
            let refused = try await summon(try await tokenOf(d, mid))
            #expect(refused.error?.message.contains("card") == true && refused.error?.message.contains(out) == true, "\(refused)")
            let list = try await send(p, Request(id: "l", token: d.adminToken, command: "access.list"))
            guard case .object(let lo)? = list.result, case .array(let cards)? = lo["cards"],
                  cards.contains(where: { if case .object(let c) = $0 { c["path"] == .string(out) && c["requested"] == .bool(true) } else { false } })
            else { Issue.record("no card: \(list)"); return }
            let g = try await send(p, Request(id: "g", token: d.adminToken, command: "access.grant", args: [
                "terminal": "M", "path": .string(out), "access": "write", "scope": "terminal"]), timeoutSeconds: 60)
            #expect(g.ok, "\(g)")
            let ok = try await summon(try await tokenOf(d, mid))
            #expect(ok.ok, "\(ok)")
        }
    }
}
