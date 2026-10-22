import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
import CollieDaemonKit

extension Tag { @Tag static var soak: Self }

private let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let soakCollied = pkg.appendingPathComponent(".build/debug/collied")
private let soakFixture = pkg.appendingPathComponent("Tests/Fixtures/fake-agent.sh").path

/// Daemon memory as the kernel accounts it (ri_phys_footprint, what Activity Monitor calls "Memory").
func footprintBytes(_ pid: pid_t) -> Int {
    var ri = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &ri) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? Int(ri.ri_phys_footprint) : -1
}

private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

@Suite(.tags(.soak), .enabled(if: ProcessInfo.processInfo.environment["COLLIE_SOAK"] == "1"))
struct SoakTests {
    /// 20 fake agents (real `collie hook` stop), 10 rounds x 20 concurrent asks from the Shepherd terminal.
    /// Per-scrollback memoryBytes is not visible outside the daemon: see AskTests.scrollbackMemoryStaysBounded.
    @Test func soakTwentyAgents() async throws {
        let root = URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")
        let proc = Process(); proc.executableURL = soakCollied; proc.arguments = ["--root", root.path]
        proc.environment = ProcessInfo.processInfo.environment.merging(["COLLIE_USER_ENV": "off"]) { $1 }
        try proc.run()
        defer {
            if proc.isRunning { kill(proc.processIdentifier, SIGTERM); proc.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        let sock = root.appendingPathComponent("run/collied.sock"), tf = root.appendingPathComponent("admin.token")
        #expect(await waitFor(5) { FileManager.default.fileExists(atPath: sock.path) && FileManager.default.fileExists(atPath: tf.path) })
        let admin = try String(contentsOf: tf, encoding: .utf8)

        func spawn(_ name: String, command: String, shepherd: Bool = false) async throws -> String {
            let r = try await UnixSocketClient.send(Request(id: "s", token: admin, command: "admin.spawn", args: [
                "name": .string(name), "preset": .string("custom"), "cwd": .string("/tmp"), "command": .string(command),
                "shepherd": .bool(shepherd)]), to: sock, timeoutSeconds: 10)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "spawn \(r)") }
            return id
        }
        let tokFile = root.appendingPathComponent("shepherd.tok")
        let shepherd = try await spawn("Shepherd", command: "echo $COLLIE_TOKEN > '\(tokFile.path)'; exec sleep 100000", shepherd: true)
        for i in 0..<20 {
            _ = try await spawn("agent\(i)", command: "COLLIE_FAKE_HOOK=cli COLLIE_CLI_PATH='\(collieURL.path)' exec sh '\(soakFixture)'")
            // a Shepherd reaches only leashed terminals
            let c = try await UnixSocketClient.send(Request(id: "c", token: admin, command: "admin.leash", args: [
                "a": .string("Shepherd"), "b": .string("agent\(i)")]), to: sock, timeoutSeconds: 10)
            #expect(c.ok, "connect agent\(i): \(c)")
        }
        #expect(await waitFor(5) { (try? String(contentsOf: tokFile, encoding: .utf8))?.count ?? 0 > 60 })
        let token = try String(contentsOf: tokFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        var latencies: [Double] = [], ok = 0, rss: [Int: Int] = [:]
        for round in 1...10 {
            let results = await withTaskGroup(of: (Double, Bool).self) { g in
                for i in 0..<20 {
                    g.addTask {
                        let prompt = "r\(round)t\(i)", t0 = ContinuousClock.now
                        let r = try? await UnixSocketClient.send(Request(id: prompt, terminalId: shepherd, token: token, command: "ask",
                            args: ["target": .string("agent\(i)"), "prompt": .string(prompt), "timeout": .number(30)]), to: sock, timeoutSeconds: 40)
                        var out = ""
                        if case .object(let o)? = r?.result, case .string(let s)? = o["output"] { out = s }
                        return (ms(ContinuousClock.now - t0), r?.ok == true && out == "answer:\(prompt)")
                    }
                }
                var all: [(Double, Bool)] = []
                for await x in g { all.append(x) }
                return all
            }
            latencies += results.map { $0.0 }; ok += results.filter { $0.1 }.count
            rss[round] = footprintBytes(proc.processIdentifier)
        }
        latencies.sort()
        let p50 = latencies[latencies.count / 2], p95 = latencies[Int(Double(latencies.count) * 0.95) - 1]
        let mib = { (b: Int) in Double(b) / 1_048_576 }
        print("SOAK success=\(ok)/200 p50=\(Int(p50))ms p95=\(Int(p95))ms footprint(r2)=\(mib(rss[2]!))MiB footprint(r10)=\(mib(rss[10]!))MiB")
        #expect(ok == 200)
        #expect(p95 < 2000)
        #expect(rss[2]! > 0 && rss[10]! <= rss[2]! + 20 * 1_048_576)

        // Stop the daemon and make sure no agent outlives it.
        kill(proc.processIdentifier, SIGTERM); proc.waitUntilExit()
        let pg = Process(); pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); pg.arguments = ["-f", root.path]
        pg.standardOutput = FileHandle.nullDevice
        try pg.run(); pg.waitUntilExit()
        #expect(pg.terminationStatus == 1, "leftover processes mention \(root.path)")
    }
}
