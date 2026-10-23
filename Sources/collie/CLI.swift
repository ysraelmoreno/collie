import Foundation
import CollieCore
import CollieProtocol
import CollieDaemonKit

/// Request construction shared by the CLI and the MCP server.
enum Client {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var socket: URL { env["COLLIE_SOCKET"].map { URL(fileURLWithPath: $0) } ?? Paths().socket }

    static func timeout(_ command: String, _ args: [String: JSONValue]) -> Double? {
        if command == "ask" {
            if case .number(let n)? = args["timeout"] { return n + 5 }
            return 1805
        }
        // plugin commands: the daemon times the call out itself; the margin lets its typed `.timeout` arrive first
        if PluginRegistry.command(command) != nil { return Commands.spec(command)?.timeoutSeconds.map { $0 + 5 } }
        return Commands.spec(command)?.timeoutSeconds
    }

    /// Sends one command. Throws `ProtocolError`; a daemon-side error is returned as the thrown error too.
    static func call(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        // `--out` is the caller's own file, written here (relative to this process's cwd; over MCP, the `collie mcp` server's cwd), never by the daemon
        var args = args
        let out = command == "browser.screenshot" ? args.removeValue(forKey: "out") : nil
        if let out, case .string = out {} else if out != nil { throw ProtocolError(code: .invalidArgs, message: "--out must be a string") }
        let result = try await send(command, args)
        guard case .string(let dest)? = out else { return result }
        return try OutFile.copyPath(of: result, to: dest, cwd: FileManager.default.currentDirectoryPath)
    }

    private static func send(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        var token = env["COLLIE_TOKEN"], terminalId = env["COLLIE_TERMINAL_ID"]
        // paddock.* / memory.* / work.* / lot.* outside a terminal (no COLLIE_TOKEN) is the user: admin token
        if command.hasPrefix("admin.") || command.hasPrefix("ui.")
            || ((command.hasPrefix("paddock.") || command.hasPrefix("memory.") || command.hasPrefix("work.") || command.hasPrefix("lot.")) && token == nil) {
            // inside a Collie terminal without its own token: never the admin file (the daemon refuses it from there anyway)
            if env["COLLIE_TERMINAL_ID"] != nil && env["COLLIE_TOKEN"] == nil {
                throw ProtocolError(code: .unauthorized, message: "the admin token can't be used from inside a Collie terminal")
            }
            let file = env["COLLIE_ADMIN_TOKEN_FILE"].map { URL(fileURLWithPath: $0) } ?? Paths().adminTokenFile
            guard let t = try? String(contentsOf: file, encoding: .utf8) else {
                throw ProtocolError(code: .unauthorized, message: "cannot read admin token at \(file.path)")
            }
            token = t.trimmingCharacters(in: .whitespacesAndNewlines); terminalId = nil
        }
        let r = try await UnixSocketClient.send(
            Request(id: UUID().uuidString, terminalId: terminalId, token: token, command: command, args: args,
                    cwd: FileManager.default.currentDirectoryPath),
            to: socket, timeoutSeconds: timeout(command, args))
        if r.ok { return r.result ?? .null }
        throw r.error ?? ProtocolError(code: .internal, message: "request failed")
    }
}

enum CLI {
    static func usage() -> String {
        var s = "usage: collie [--json] <command> [args]\n       collie mcp\n\ncommands:\n"
        for c in Commands.all where c.name != "turn.completed" && !c.name.hasPrefix("ui.") {
            let name = c.name.replacingOccurrences(of: ".", with: " ")
            s += "  \(name)\t\(c.summary)\n"
        }
        return s
    }

    static func err(_ m: String) { FileHandle.standardError.write(Data("collie: \(m)\n".utf8)) }

    static func run(_ raw: [String]) async -> Int32 {
        var argv = raw
        var json = false
        let end = argv.firstIndex(of: "--") ?? argv.count
        if let i = argv[..<end].firstIndex(of: "--json") { argv.remove(at: i); json = true }
        if argv.first == "help" || argv.first == "--help" { print(usage(), terminator: ""); return 0 }
        if argv.isEmpty { FileHandle.standardError.write(Data(usage().utf8)); return 2 }
        let cmd: (command: String, args: [String: JSONValue])
        do { cmd = try ArgvParser.parse(argv) } catch { err(error.message); return 2 }
        do {
            let result = try await Client.call(cmd.command, cmd.args)
            print(render(cmd.command, result, json: json), terminator: "")
            if case .object(let o) = result, case .bool(true)? = o["truncated"] { err("output truncated") }
            return 0
        } catch {
            err(error.message)
            return error.code == .daemonUnavailable ? 3 : 1
        }
    }

    static func jsonString(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func render(_ command: String, _ result: JSONValue, json: Bool) -> String {
        if json { return jsonString(result) + "\n" }
        func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { return s }; return "" }
        switch (command, result) {
        case ("list", .array(let rows)):
            return rows.map { row -> String in
                guard case .object(let o) = row else { return "" }
                var line = "\(str(o["name"]))\t\(str(o["preset"]))\t\(o["running"] == .bool(true) ? "running" : "stopped")"
                if o["isShepherd"] == .bool(true) { line += "\tshepherd" }
                return line + "\n"
            }.joined()
        case (_, .object(let o)) where o["output"] != nil:
            let s = str(o["output"]); return s.hasSuffix("\n") ? s : s + "\n"
        case ("admin.spawn", .object(let o)): return str(o["id"]) + "\n"
        case (_, .null): return ""
        default: return jsonString(result) + "\n"
        }
    }
}
