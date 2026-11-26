import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// A fake device recording each command; `device.screen` answers `sig` "s".
private actor Recorder {
    var commands: [String] = []
    func act(_ c: String) -> JSONValue { commands.append(c); return c == "device.screen" ? .object(["sig": .string("s")]) : .object([:]) }
}
private func run(_ json: String, confirmed: Bool = false, _ d: Recorder) async throws -> JSONValue {
    try await FlowRunner(confirmed: confirmed) { c, _ async throws(ProtocolError) in await d.act(c) }.run(try FlowPlan.parse(Data(json.utf8)))
}

private let checkout = #"""
{"steps":[{"action":"tap","target":"Carrinho","expectSig":"s"},{"action":"tap","target":"Revisar"},
          {"action":"tap","target":"Finalizar pedido","destructive":true},{"action":"key","target":"Back"}]}
"""#

/// d7: a `destructive` step runs only with the user's `--confirm-destructive`. Nested in DeviceCommandTests: the daemon
/// tests drive the fake adb through process-wide environment variables, as that suite does.
extension DeviceCommandTests {
    @Suite struct FlowDestructiveTests {
        @Test func destructiveStepIsRefusedAndEarlierStepsStayRunAndReported() async throws {
            let d = Recorder()
            let r = try await run(checkout, d)
            #expect(r == .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(3), "done": .number(2)]))
            #expect(await d.commands == ["device.tap", "device.screen", "device.tap"])   // Finalizar and Back never ran
        }

        @Test func aDestructiveFirstStepRunsNothing() async throws {
            let d = Recorder()
            let r = try await run(#"{"steps":[{"action":"tap","target":"Excluir","destructive":true},{"action":"key","target":"Back"}]}"#, d)
            #expect(r == .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(1), "done": .number(0)]))
            #expect(await d.commands.isEmpty)
        }

        @Test func confirmedPlanRunsTheDestructiveStep() async throws {
            let d = Recorder()
            let r = try await run(checkout, confirmed: true, d)
            #expect(r == .object(["ok": .bool(true), "steps": .number(4)]))
            #expect(await d.commands == ["device.tap", "device.screen", "device.tap", "device.tap", "device.key"])
        }

        @Test func planWithoutDestructiveStepIsUnaffected() async throws {
            let d = Recorder()
            let r = try await run(#"{"steps":[{"action":"tap","target":"OK","destructive":false},{"action":"key","target":"Back"}]}"#, d)
            #expect(r == .object(["ok": .bool(true), "steps": .number(2)]))
            #expect(await d.commands == ["device.tap", "device.key"])
        }

        @Test func commandDeclaresTheFlag() throws {
            let spec = try #require(Commands.spec("device.run"))
            #expect(spec.params.contains { $0.name == "confirm-destructive" })
            #expect(try ArgvParser.parse(["device", "run", "--plan", "p.json", "--confirm-destructive"]).args["confirm-destructive"] == .bool(true))
        }

        /// Through the daemon: the agent's flag is refused before the plan is read, the agent's plan stops at the
        /// destructive step, and the user's flag runs it.
        @Test func daemonRefusesTheAgentsFlagAndRunsTheUsers() async throws {
            let dir = URL(fileURLWithPath: "/tmp/collie-flowdestr-\(UUID().uuidString.prefix(8))")
            let paddock = dir.appendingPathComponent("k")
            try FileManager.default.createDirectory(at: paddock, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try "List of devices attached\nemulator-5554          device product:sdk_gphone model:Pixel_7 device:emu\n"
                .write(to: dir.appendingPathComponent("devices"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("logcat"), atomically: true, encoding: .utf8)
            let log = dir.appendingPathComponent("adb.log")
            try Data().write(to: log)
            setenv("COLLIE_FAKE_ADB_LOG", log.path, 1)
            setenv("COLLIE_FAKE_ADB_DEVICES", dir.appendingPathComponent("devices").path, 1)
            setenv("COLLIE_FAKE_ADB_LOGCAT", dir.appendingPathComponent("logcat").path, 1)
            setenv("COLLIE_FAKE_ADB_PNG", fixtures.appendingPathComponent("screen.png").path, 1)
            setenv("COLLIE_FAKE_ADB_UI", fixtures.appendingPathComponent("ui-dump.xml").path, 1)
            unsetenv("COLLIE_FAKE_ADB_TTY")
            let planFile = paddock.appendingPathComponent("plan.json")
            try #"{"steps":[{"action":"key","target":"Tab"},{"action":"key","target":"Enter","destructive":true}]}"#
                .write(to: planFile, atomically: true, encoding: .utf8)

            try await withDaemon(configure: {
                $0.adbPath = fixtures.appendingPathComponent("fake-adb.sh")
                $0.emulatorPath = URL(fileURLWithPath: "/nonexistent")
            }) { d, p in
                func send(_ r: Request) async throws -> Response { try await UnixSocketClient.send(r, to: p.socket, timeoutSeconds: 60) }
                #expect(try await send(Request(id: "x", token: d.adminToken, command: "paddock.create",
                                               args: ["name": .string("k"), "folder": .string(paddock.path)])).ok)
                let s = try await send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
                    args: ["name": .string("A"), "preset": .string("shell"), "paddock": .string("k"), "shepherd": .bool(true)]))
                guard case .object(let so)? = s.result, case .string(let id)? = so["id"] else { Issue.record("\(s)"); return }
                let token = try await tokenOf(d, id)
                func agent(_ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
                    try await send(Request(id: "m", terminalId: id, token: token, command: cmd, args: args, cwd: paddock.path))
                }
                #expect(try await agent("panel.open", ["plugin": .string("device")]).ok)

                let forged = try await agent("device.run", ["plan": .string(planFile.path), "confirm-destructive": .bool(true)])
                #expect(!forged.ok && forged.error?.code == .unauthorized, "\(forged)")
                #expect(try String(contentsOf: log, encoding: .utf8).contains("keyevent") == false)   // nothing ran

                let mine = try await agent("device.run", ["plan": .string(planFile.path)])
                #expect(mine.ok && mine.result == .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(2), "done": .number(1)]), "\(mine)")
                let afterAgent = try String(contentsOf: log, encoding: .utf8)
                #expect(afterAgent.contains("keyevent 61") && !afterAgent.contains("keyevent 66"), "\(afterAgent)")   // Tab ran, Enter did not

                let user = try await send(Request(id: "x", token: d.adminToken, command: "device.run",
                    args: ["plan": .string(planFile.path), "confirm-destructive": .bool(true)]))
                #expect(user.ok && user.result == .object(["ok": .bool(true), "steps": .number(2)]), "\(user)")
                #expect(try String(contentsOf: log, encoding: .utf8).contains("keyevent 66"))
            }
        }
    }
}
