import Testing
import Foundation
import Darwin
import OrqCore
import OrqProtocol
import OrqDaemonKit

private let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let orqURL = pkg.appendingPathComponent(".build/debug/orq")
private let orqdURL = pkg.appendingPathComponent(".build/debug/orqd")
private let fixture = pkg.appendingPathComponent("Tests/Fixtures/fake-agent.sh").path

/// Waits for a positive condition; `seconds` is floored at 20 s (free when it passes, absorbs a loaded machine).
func waitFor(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(max(seconds, 20))
    while ContinuousClock.now < deadline { if cond() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return cond()
}

private final class Box: @unchecked Sendable { var d = Data() }
struct Run { var status: Int32; var out: String; var err: String }

/// Runs `orq` off the cooperative pool and waits for exit.
func runOrq(_ args: [String], env: [String: String], stdin: String? = nil) async throws -> Run {
    try await withCheckedThrowingContinuation { c in
        Thread {
            do {
                let p = Process(); p.executableURL = orqURL; p.arguments = args
                p.environment = ProcessInfo.processInfo.environment.merging(["ORQ_USER_ENV": "off"].merging(env) { $1 }) { $1 }
                let o = Pipe(), e = Pipe(), i = Pipe()
                p.standardOutput = o; p.standardError = e; p.standardInput = i
                try p.run()
                if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? i.fileHandleForWriting.close()
                let od = Box(), ed = Box()
                let g = DispatchGroup()
                g.enter(); Thread { od.d = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }.start()
                g.enter(); Thread { ed.d = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }.start()
                p.waitUntilExit(); g.wait()
                c.resume(returning: Run(status: p.terminationStatus, out: String(decoding: od.d, as: UTF8.self), err: String(decoding: ed.d, as: UTF8.self)))
            } catch { c.resume(throwing: error) }
        }.start()
    }
}

/// A live orqd process with terminals A and B (connected, fake-agent) and their credentials.
struct Rig {
    var root: URL; var socket: URL; var adminTokenFile: URL
    var aId: String, aToken: String, bId: String, bToken: String
    var env: [String: String] { ["ORQ_SOCKET": socket.path, "ORQ_TERMINAL_ID": aId, "ORQ_TOKEN": aToken, "ORQ_ADMIN_TOKEN_FILE": adminTokenFile.path] }
}

func withRig(_ body: (Rig) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let proc = Process(); proc.executableURL = orqdURL; proc.arguments = ["--root", root.path]
    proc.environment = ProcessInfo.processInfo.environment.merging(["ORQ_USER_ENV": "off"]) { $1 }
    try proc.run()
    defer { if proc.isRunning { kill(proc.processIdentifier, SIGTERM); proc.waitUntilExit() } }
    let sock = root.appendingPathComponent("run/orqd.sock"), tf = root.appendingPathComponent("admin.token")
    #expect(await waitFor(5) { FileManager.default.fileExists(atPath: sock.path) && FileManager.default.fileExists(atPath: tf.path) })
    let admin = try String(contentsOf: tf, encoding: .utf8)
    func spawn(_ name: String) async throws -> (String, String) {
        let tokFile = root.appendingPathComponent("\(name).tok")
        let cmd = "echo $ORQ_TOKEN > '\(tokFile.path)'; ORQ_FAKE_HOOK=cli ORQ_CLI_PATH='\(orqURL.path)' exec sh '\(fixture)'"
        let r = try await UnixSocketClient.send(Request(id: "s", token: admin, command: "admin.spawn", args: [
            "name": .string(name), "preset": .string("custom"), "cwd": .string("/tmp"), "command": .string(cmd)]), to: sock, timeoutSeconds: 5)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "spawn \(r)") }
        #expect(await waitFor(5) { (try? String(contentsOf: tokFile, encoding: .utf8))?.count ?? 0 > 60 })
        return (id, try String(contentsOf: tokFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let (a, at) = try await spawn("A"), (b, bt) = try await spawn("B")
    let c = try await UnixSocketClient.send(Request(id: "c", token: admin, command: "admin.connect", args: ["a": .string("A"), "b": .string("B")]), to: sock, timeoutSeconds: 5)
    #expect(c.ok)
    try await body(Rig(root: root, socket: sock, adminTokenFile: tf, aId: a, aToken: at, bId: b, bToken: bt))
}
