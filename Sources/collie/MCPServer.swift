import Foundation
import CollieProtocol

/// JSON-RPC 2.0 over stdio, one message per line. Requests run concurrently; stdout writes are locked.
enum MCPServer {
    private static let lock = NSLock()
    private static var shepherd: Bool { ProcessInfo.processInfo.environment["COLLIE_SHEPHERD"] == "1" }
    /// Every tool this terminal could call; `tools/call` checks against it (the daemon enforces reach).
    private static var tools: [JSONValue] { MCPSchema.tools(shepherd: shepherd) }
    private nonisolated(unsafe) static var initialized = false, lastReach: Set<String>?   // under `lock`

    /// Plug-in ids of the panels this terminal reaches (the daemon applies the leashes); an error reaches none.
    private static func reach() async -> Set<String> {
        guard case .array(let ps)? = try? await Client.call("panel.list", [:]) else { return [] }
        return Set(ps.compactMap { if case .object(let o) = $0, case .string(let id)? = o["pluginId"] { id } else { nil } })
    }
    /// Sends `notifications/tools/list_changed` when the reached plug-ins change after `initialize`.
    // ponytail: poll 10 s; trocar por stream de eventos se custar
    private static func poll() async {
        let ms = max(50, ProcessInfo.processInfo.environment["COLLIE_MCP_POLL_MS"].flatMap(Int.init) ?? 10_000)   // tests shorten it
        while (try? await Task.sleep(for: .milliseconds(ms))) != nil {
            guard lock.withLock({ initialized }) else { continue }
            let now = await reach()
            let changed = lock.withLock { () -> Bool in
                defer { lastReach = now }
                return lastReach != nil && lastReach != now
            }
            if changed { write(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"]) }
        }
    }
    private static func write(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return }
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardOutput.write(d + Data("\n".utf8))
    }
    private static func reply(_ id: Any, _ result: Any) { write(["jsonrpc": "2.0", "id": id, "result": result]) }
    private static func fail(_ id: Any, _ code: Int, _ msg: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]])
    }

    static func run() async {
        if ProcessInfo.processInfo.environment["COLLIE_TOKEN"] == nil {
            FileHandle.standardError.write(Data("collie mcp: COLLIE_TOKEN not set (not in an Collie terminal); listing only the core and panel-free tools\n".utf8))
        }
        let poller = Task { await poll() }
        defer { poller.cancel() }
        await withTaskGroup(of: Void.self) { group in
            // ponytail: blocking stdin read on one task; fine since stdin EOF ends the server.
            let lines = AsyncStream<String> { c in
                Thread {
                    while let l = readLine(strippingNewline: true) { c.yield(l) }
                    c.finish()
                }.start()
            }
            for await line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                group.addTask { await handle(line) }
            }
        }
    }

    private static func handle(_ line: String) async {
        guard let any = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return fail(NSNull(), -32700, "parse error")
        }
        guard let o = any as? [String: Any] else { return fail(NSNull(), -32600, "invalid request") }
        guard let method = o["method"] as? String else { return fail(o["id"] ?? NSNull(), -32600, "invalid request") }
        guard let id = o["id"], !method.hasPrefix("notifications/") else { return }
        switch method {
        case "initialize":
            lock.withLock { initialized = true }
            reply(id, ["protocolVersion": "2025-06-18", "capabilities": ["tools": ["listChanged": true]],
                       "serverInfo": ["name": "collie", "version": "0.1.0"]])
        case "ping": reply(id, [String: Any]())
        case "tools/list":
            let now = await reach()
            lock.withLock { lastReach = now }
            let tools = (try? JSONEncoder().encode(MCPSchema.tools(shepherd: shepherd, plugins: now))).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
            reply(id, ["tools": tools])
        case "tools/call":
            let p = o["params"] as? [String: Any] ?? [:]
            reply(id, await call(name: p["name"] as? String ?? "", arguments: p["arguments"] as? [String: Any] ?? [:]))
        default: fail(id, -32601, "method not found: \(method)")
        }
    }

    private static func content(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func call(name: String, arguments: [String: Any]) async -> [String: Any] {
        guard tools.contains(where: { if case .object(let t) = $0 { return t["name"] == .string(name) }; return false }) else {
            return content("invalidArgs: unknown tool '\(name)'", isError: true)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let args = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return content("invalidArgs: bad arguments", isError: true)
        }
        guard let command = Commands.all.first(where: { $0.mcpName == name })?.name else {
            return content("invalidArgs: unknown tool '\(name)'", isError: true)
        }
        do {
            let result = try await Client.call(command, args)
            if case .object(let r) = result, case .string(let out)? = r["output"] {
                return content(r["truncated"] == .bool(true) ? out + "\n[collie: output truncated]" : out, isError: false)
            }
            return content(CLI.jsonString(result), isError: false)
        } catch {
            return content("\(error.code.rawValue): \(error.message)", isError: true)
        }
    }
}
