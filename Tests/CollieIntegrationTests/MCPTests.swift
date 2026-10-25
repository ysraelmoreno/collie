import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieDaemonKit

/// A fake daemon answering `panel.list` with panels of `plugins` (mutable), `plugin.specs` with `specs` (nil: null, as
/// a daemon without plug-ins support), anything else ok/null; every request is kept in `calls`.
private final class FakeDaemon: @unchecked Sendable {
    let socket = URL(fileURLWithPath: "/tmp/collie-fd-\(UUID().uuidString.prefix(8)).sock")
    private let lock = NSLock(); private var _plugins: [String]; private var _specs: [JSONValue]?; private var _calls: [Request] = []
    var plugins: [String] { get { lock.withLock { _plugins } } set { lock.withLock { _plugins = newValue } } }
    var specs: [JSONValue]? { get { lock.withLock { _specs } } set { lock.withLock { _specs = newValue } } }
    var calls: [Request] { lock.withLock { _calls } }
    private var server: UnixSocketServer?
    init(_ plugins: [String], specs: [JSONValue]? = nil) throws {
        _plugins = plugins; _specs = specs
        let s = UnixSocketServer(path: socket) { [unowned self] r in
            self.lock.withLock { self._calls.append(r) }
            if r.command == "plugin.specs" {
                return Response(id: r.id, ok: true, result: self.specs.map { .object(["plugins": .array($0)]) } ?? .null)
            }
            guard r.command == "panel.list" else { return Response(id: r.id, ok: true, result: .null) }
            return Response(id: r.id, ok: true, result: .array(self.plugins.map { .object(["pluginId": .string($0), "name": .string($0)]) }))
        }
        try s.start(); server = s
    }
    deinit { server?.stop(); try? FileManager.default.removeItem(at: socket) }
    var env: [String: String] { ["COLLIE_SOCKET": socket.path, "COLLIE_TERMINAL_ID": UUID().uuidString, "COLLIE_TOKEN": "t"] }
}

/// A long-lived `collie mcp` session: stdin stays open until `close()`.
private final class Session: @unchecked Sendable {
    let p = Process(); let i = Pipe(), o = Pipe()
    private let lock = NSLock(); private var buf = Data()
    var messages: [[String: Any]] { lines(String(decoding: lock.withLock { buf }, as: UTF8.self)) }
    init(env: [String: String]) throws {
        p.executableURL = collieURL; p.arguments = ["mcp"]
        p.environment = ProcessInfo.processInfo.environment.merging(["COLLIE_USER_ENV": "off"].merging(env) { $1 }) { $1 }
        p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        o.fileHandleForReading.readabilityHandler = { [weak self] h in let d = h.availableData; self?.lock.withLock { self?.buf.append(d) } }
        try p.run()
    }
    func send(_ line: String) { i.fileHandleForWriting.write(Data((line + "\n").utf8)) }
    func close() { try? i.fileHandleForWriting.close(); p.waitUntilExit(); o.fileHandleForReading.readabilityHandler = nil }
}

/// The notas example's manifest, as `plugin.specs` carries it.
private let notas: JSONValue = try! JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas/collie-plugin.json")))

private func toolNames(_ m: [String: Any]?) -> Set<String> {
    Set(((m?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
}

private func lines(_ s: String) -> [[String: Any]] {
    s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

@Suite struct MCPTests {
    @Test func mcpListsTools() async throws {
        let input = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
            + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
            + #"{"jsonrpc":"2.0","id":3,"method":"nope"}"# + "\n"
            + "{bad\n"
        let r = try await runCollie(["mcp"], env: ["COLLIE_SOCKET": "/nonexistent/x.sock"], stdin: input)
        #expect(r.status == 0)
        let m = lines(r.out)
        #expect(m.count == 4)
        func by(_ id: Int) -> [String: Any]? { m.first { $0["id"] as? Int == id } }
        #expect(((by(1)?["result"] as? [String: Any])?["protocolVersion"] as? String) == "2025-06-18")
        let tools = (by(2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        // no daemon: panel.list fails, so only the core and panel-free tools (no plug-in reached)
        #expect(tools?.compactMap { $0["name"] as? String }.sorted() == ["ask", "check", "paddock_list", "paddock_status", "list", "panel_list", "panel_open", "panel_close", "panel_move", "events",
                         "memory_save", "memory_search", "memory_list", "memory_get", "memory_context", "memory_checklist", "memory_promote", "device_list",
                         "work_start", "work_done", "work_reopen", "work_task_add", "work_task_done", "work_task_defer", "work_task_drop",
                         "work_note", "work_status", "work_summary", "work_list", "work_get", "lot_leave", "lot_list", "lot_get", "lot_post", "lot_board", "comment_reply", "comment_list", "access_request", "access_list",
                         "design_files", "design_new", "design_help", "design_prefer", "design_system_list", "design_system_create", "design_system_history",
                         "design_system_use", "design_system_undo", "artifact_list", "artifact_get", "artifact_add", "artifact_import", "artifact_new", "artifact_libs"].sorted())
        if ProcessInfo.processInfo.environment["COLLIE_TOKEN"] == nil {   // no credential: one line on stderr
            #expect(r.err.split(separator: "\n").filter { $0.contains("COLLIE_TOKEN") }.count == 1, "\(r.err)")
        }
        let caps = (by(1)?["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        #expect((caps?["tools"] as? [String: Any])?["listChanged"] as? Bool == true)
        #expect(((by(3)?["error"] as? [String: Any])?["code"] as? Int) == -32601)
        #expect(m.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 && $0["id"] is NSNull })
    }
    @Test func mcpListsShepherdToolsWithShepherdEnv() async throws {
        let input = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n"
        let r = try await runCollie(["mcp"], env: ["COLLIE_SOCKET": "/nonexistent/x.sock", "COLLIE_SHEPHERD": "1"], stdin: input)
        let tools = (lines(r.out).first?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.compactMap { $0["name"] as? String }.contains("summon") == true)
    }
    @Test func toolsFollowReach() async throws {
        let d = try FakeDaemon([])
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n"
        let none = toolNames(lines(try await runCollie(["mcp"], env: d.env, stdin: list).out).first)
        #expect(none.isSuperset(of: ["ask", "memory_save", "panel_list", "design_files", "design_system_list", "artifact_add", "device_list"]))
        #expect(!none.contains("design_run") && !none.contains("design_system_publish") && !none.contains("device_tap")
                && !none.contains { $0.hasPrefix("browser_") } && !none.contains("summon"))
        d.plugins = ["design"]
        let r = lines(try await runCollie(["mcp"], env: d.env, stdin: list).out).first
        let some = toolNames(r)
        #expect(some.contains("design_run") && some.contains("design_system_list") && !some.contains { $0.hasPrefix("browser_") })
        let run = ((r?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "design_run" }
        #expect((run?["description"] as? String)?.hasPrefix("Collie Design panel leashed to you: ") == true)
        let files = ((r?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "design_files" }
        #expect((files?["description"] as? String)?.hasPrefix("Collie Design") == false)
        var shepherdEnv = d.env; shepherdEnv["COLLIE_SHEPHERD"] = "1"
        #expect(toolNames(lines(try await runCollie(["mcp"], env: shepherdEnv, stdin: list).out).first).contains("summon"))
    }
    @Test func listChangedOnReachChange() async throws {
        let d = try FakeDaemon([])
        var env = d.env; env["COLLIE_MCP_POLL_MS"] = "100"
        let s = try Session(env: env)
        s.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        s.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        s.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(await waitFor(5) { s.messages.contains { $0["id"] as? Int == 2 } })
        try await Task.sleep(for: .milliseconds(500))   // unchanged reach: no notification
        func changed() -> Int { s.messages.filter { $0["method"] as? String == "notifications/tools/list_changed" }.count }
        #expect(changed() == 0)
        d.plugins = ["browser"]
        #expect(await waitFor(5) { changed() == 1 })
        s.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        #expect(await waitFor(5) { toolNames(s.messages.first { $0["id"] as? Int == 3 }).contains("browser_navigate") })
        try await Task.sleep(for: .milliseconds(500))
        #expect(changed() == 1)
        s.close()
        #expect(s.p.terminationStatus == 0)
    }
    /// Review Focus 4: an external plug-in's panel-bound tools follow reach like a built-in's.
    @Test func mcpListsExternalOnlyWhenReached() async throws {
        let d = try FakeDaemon([], specs: [notas])
        let list = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n" + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
        func listed() async throws -> [String: Any]? { lines(try await runCollie(["mcp"], env: d.env, stdin: list).out).first { $0["id"] as? Int == 2 } }
        #expect(!toolNames(try await listed()).contains { $0.hasPrefix("notas_") })
        d.plugins = ["notas"]
        let r = try await listed()
        #expect(toolNames(r).isSuperset(of: ["notas_add", "notas_list", "notas_export"]), "\(String(describing: r))")
        let export = ((r?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "notas_export" }
        let props = ((export?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        #expect(props["format"] != nil && props["out"] != nil && props["panel"] != nil)
        // a call reaches the daemon as the dotted command, with its args
        let call = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notas_add","arguments":{"text":"comprar café"}}}"# + "\n"
        let out = lines(try await runCollie(["mcp"], env: d.env, stdin: call).out)
        #expect((out.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])?["isError"] as? Bool == false, "\(out)")
        #expect(d.calls.contains { $0.command == "notas.add" && $0.args["text"] == .string("comprar café") })
    }
    @Test func mcpListChangedAfterInstall() async throws {
        let d = try FakeDaemon(["notas"], specs: [])
        var env = d.env; env["COLLIE_MCP_POLL_MS"] = "100"
        let s = try Session(env: env)
        s.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        s.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        s.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(await waitFor(5) { s.messages.contains { $0["id"] as? Int == 2 } })
        #expect(!toolNames(s.messages.first { $0["id"] as? Int == 2 }).contains("notas_add"))
        func changed() -> Int { s.messages.filter { $0["method"] as? String == "notifications/tools/list_changed" }.count }
        try await Task.sleep(for: .milliseconds(500))
        #expect(changed() == 0)
        d.specs = [notas]   // installed
        #expect(await waitFor(5) { changed() == 1 })
        s.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        #expect(await waitFor(5) { toolNames(s.messages.first { $0["id"] as? Int == 3 }).contains("notas_add") })
        try await Task.sleep(for: .milliseconds(500))
        #expect(changed() == 1)
        d.specs = []   // removed
        #expect(await waitFor(5) { changed() == 2 })
        s.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        #expect(await waitFor(5) { s.messages.contains { $0["id"] as? Int == 4 } })
        #expect(!toolNames(s.messages.first { $0["id"] as? Int == 4 }).contains("notas_add"))
        s.close()
    }
    @Test func cliResolvesExternalAfterFetch() async throws {
        let d = try FakeDaemon([], specs: [notas])
        let r = try await runCollie(["notas", "add", "comprar", "café"], env: d.env)
        #expect(r.status == 0, "\(r)")
        #expect(d.calls.map(\.command) == ["plugin.specs", "notas.add"])
        #expect(d.calls.last?.args["text"] == .string("comprar café"))
        // no such plug-in: still the parse error, after the one fetch
        let u = try await runCollie(["kanban", "add", "x"], env: d.env)
        #expect(u.status == 2 && u.err.contains("unknown command"), "\(u)")
        // a built-in command never fetches
        _ = try await runCollie(["list"], env: d.env)
        #expect(d.calls.filter { $0.command == "plugin.specs" }.count == 2)
    }
    @Test func mcpCallAsk() async throws {
        try await withRig { rig in
            let input = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"target":"B","prompt":"hi"}}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"admin.kill","arguments":{"target":"B"}}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list","arguments":{}}}"# + "\n"
            let r = try await runCollie(["mcp"], env: rig.env, stdin: input)
            let m = lines(r.out)
            func text(_ id: Int) -> (String, Bool)? {
                guard let res = m.first(where: { $0["id"] as? Int == id })?["result"] as? [String: Any],
                      let c = (res["content"] as? [[String: Any]])?.first else { return nil }
                return (c["text"] as? String ?? "", res["isError"] as? Bool ?? true)
            }
            #expect(text(1)?.0.contains("answer:hi") == true && text(1)?.1 == false)
            #expect(text(2)?.1 == true)
            #expect(text(3)?.0.contains("\"name\"") == true && text(3)?.1 == false)
        }
    }

    @Test func mcpCallPaddockList() async throws {
        try await withRig { rig in
            let input = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"paddock_list","arguments":{}}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"paddock.list","arguments":{}}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"paddock_status","arguments":{"name":"x","status":"review"}}}"# + "\n"
            let r = try await runCollie(["mcp"], env: rig.env, stdin: input)
            let m = lines(r.out)
            func text(_ id: Int) -> (String, Bool)? {
                guard let res = m.first(where: { $0["id"] as? Int == id })?["result"] as? [String: Any],
                      let c = (res["content"] as? [[String: Any]])?.first else { return nil }
                return (c["text"] as? String ?? "", res["isError"] as? Bool ?? true)
            }
            #expect(text(1)?.0 == "[]" && text(1)?.1 == false, "\(r.out)")
            #expect(text(2)?.1 == true)   // the dotted name is not a tool
            #expect(text(3)?.0.hasPrefix("notFound") == true, "\(r.out)")   // reached the daemon
        }
    }

    @Test func mcpSignalsTruncation() async throws {
        try await withRig { rig in
            let admin = try String(contentsOf: rig.adminTokenFile, encoding: .utf8)
            let r = try await UnixSocketClient.send(Request(id: "s", token: admin, command: "admin.spawn", args: [
                "name": .string("F"), "preset": .string("custom"), "cwd": .string("/tmp"),
                "command": .string("head -c 1300000 /dev/zero | tr '\\0' x; sleep 30")]), to: rig.socket, timeoutSeconds: 5)
            #expect(r.ok)
            let c = try await UnixSocketClient.send(Request(id: "c", token: admin, command: "admin.leash", args: ["a": .string("A"), "b": .string("F")]), to: rig.socket, timeoutSeconds: 5)
            #expect(c.ok)
            let input = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"check","arguments":{"target":"F"}}}"# + "\n"
            var text = ""
            for _ in 0..<20 {
                let out = try await runCollie(["mcp"], env: rig.env, stdin: input)
                text = (((lines(out.out).first?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                if text.hasSuffix("[collie: output truncated]") { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(text.hasSuffix("[collie: output truncated]"))
        }
    }
    @Test func mcpInvalidRequest() async throws {
        let r = try await runCollie(["mcp"], env: ["COLLIE_SOCKET": "/nonexistent/x.sock"], stdin: "{\"jsonrpc\":\"2.0\",\"id\":7}\n[1]\n")
        let m = lines(r.out)
        #expect(m.count == 2 && m.allSatisfy { ($0["error"] as? [String: Any])?["code"] as? Int == -32600 })
        #expect(m.contains { $0["id"] as? Int == 7 } && m.contains { $0["id"] is NSNull })
    }
}
