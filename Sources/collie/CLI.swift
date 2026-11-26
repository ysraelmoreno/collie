import Foundation
import CryptoKit
import CollieCore
import CollieProtocol
import CollieDaemonKit

/// Request construction shared by the CLI and the MCP server.
enum Client {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var socket: URL { env["COLLIE_SOCKET"].map { URL(fileURLWithPath: $0) } ?? Paths().socket }

    static func timeout(_ command: String, _ args: [String: JSONValue]) -> Double? {
        if command == "ask" || command == "wait" || command == "work.wait" || command == "model" && args["wait"] == .bool(true) {
            let margin: Double = command == "model" ? 20 : 5   // model: the switch itself after the wait
            if case .number(let n)? = args["timeout"] { return n + margin }
            return (command == "work.wait" ? 600 : 1800) + margin   // work wait: its own default (`workWaitDefault`)
        }
        // plugin commands: the daemon times the call out itself; the margin lets its typed `.timeout` arrive first
        if PluginRegistry.command(command) != nil { return Commands.spec(command)?.timeoutSeconds.map { $0 + 5 } }
        return Commands.spec(command)?.timeoutSeconds
    }

    /// Sends one command. Throws `ProtocolError`; a daemon-side error is returned as the thrown error too.
    static func call(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        // `--out` is the caller's own file, written here (relative to this process's cwd; over MCP, the `collie mcp` server's cwd), never by the daemon
        var args = args
        let out = Commands.outputFile.contains(command) ? args.removeValue(forKey: "out") : nil
        if let out, case .string = out {} else if out != nil { throw ProtocolError(code: .invalidArgs, message: "--out must be a string") }
        if command == "diagram.set", let from = args.removeValue(forKey: "from") { args["xml"] = .string(try diagramFrom(from, args)) }
        // F5: the PRD is the owner's own file, read here (relative to this process's cwd) and sent as its text
        if command == "work.prd.add", let file = args.removeValue(forKey: "file") {
            guard case .string(let path) = file else { throw ProtocolError(code: .invalidArgs, message: "<file> must be a path") }
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/"))
            do throws(ProtocolError) { args["content"] = .string(try DiagramFile.readLocal(url)) }
            catch { throw ProtocolError(code: .invalidArgs, message: "\(path): \(error.message)") }
        }
        let result = try await send(command, args)
        guard case .string(let dest)? = out else { return result }
        return try OutFile.copyPath(of: result, to: dest, cwd: FileManager.default.currentDirectoryPath)
    }

    /// Learns the daemon's external plug-ins (`plugin.specs`) into this process's registry. false: none, or no answer.
    static func fetchPlugins() async -> Bool {
        guard let r = try? await call("plugin.specs", [:]), let ms = PluginManifest.fromSpecs(r) else { return false }
        PluginManifest.register(ms)
        return !ms.isEmpty
    }

    /// `diagram.set --from PATH`: the caller's own file, read here (relative to this process's cwd), sent as `xml`.
    static func diagramFrom(_ from: JSONValue, _ args: [String: JSONValue]) throws(ProtocolError) -> String {
        guard case .string(let path) = from else { throw ProtocolError(code: .invalidArgs, message: "--from must be a path") }
        guard args["xml"] == nil else { throw ProtocolError(code: .invalidArgs, message: "give --xml or --from, not both") }
        let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/"))
        do throws(ProtocolError) { return try DiagramFile.readLocal(url) }   // regular file ≤ 8 MiB, never blocks
        catch { throw ProtocolError(code: .invalidArgs, message: "--from \(path): \(error.message)") }
    }

    private static func send(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        var token = env["COLLIE_TOKEN"], terminalId = env["COLLIE_TERMINAL_ID"]
        // paddock.* / memory.* / work.* / lot.* outside a terminal (no COLLIE_TOKEN) is the user: admin token
        if command.hasPrefix("admin.") || command.hasPrefix("ui.") || command.hasPrefix("android.") || command.hasPrefix("design.engine.")
            || ((command.hasPrefix("paddock.") || command.hasPrefix("memory.") || command.hasPrefix("work.") || command.hasPrefix("lot.")
                 || command.hasPrefix("plugin.")) && token == nil) {
            // inside a Collie terminal: never the admin file (the daemon refuses it from there anyway)
            if env["COLLIE_TERMINAL_ID"] != nil {
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
        // CLI and MCP (both call through here): a command an older daemon lacks says to restart the service
        throw RestartHint.wrap(r.error ?? ProtocolError(code: .internal, message: "request failed"), text: RestartHint.localized)
    }
}

/// `collie plugin tree-hash|catalog-keygen|catalog-sign|catalog-verify`: local tools for publishing plug-ins and the
/// signed catalog (PRD M4, `.github/workflows/plugins-release.yml`), no daemon. The private key is read from the
/// environment only, never argv.
enum PluginPublishCLI {
    static let commands: Set<String> = ["tree-hash", "catalog-keygen", "catalog-sign", "catalog-verify"]
    static let usage = """
        usage: collie plugin tree-hash <pasta>
               collie plugin catalog-keygen --out <arquivo>
               collie plugin catalog-sign <plugins.json> --key-env <VAR>
               collie plugin catalog-verify <plugins.json> --public <base64>
        """

    static func run(_ a: [String]) -> Int32 {
        func fail(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        func read(_ path: String) throws(ProtocolError) -> Data {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw fail(tr("não consegui ler \(path)", "could not read \(path)")) }
            return d
        }
        do throws(ProtocolError) {
            switch a.first {
            case "tree-hash" where a.count == 2:
                print(try PluginTree.hash(URL(fileURLWithPath: a[1])))
            case "catalog-keygen" where a.count == 3 && a[1] == "--out":
                let key = Curve25519.Signing.PrivateKey()
                let b = Data(key.rawRepresentation.base64EncodedString().utf8)
                let fd = open(a[2], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)   // never overwrites
                guard fd >= 0 else { throw fail(tr("não consegui criar \(a[2]) (já existe?)", "could not create \(a[2]) (already exists?)")) }
                let n = b.withUnsafeBytes { write(fd, $0.baseAddress, b.count) }
                close(fd)
                guard n == b.count else { unlink(a[2]); throw fail(tr("não consegui gravar \(a[2])", "could not write \(a[2])")) }
                print(key.publicKey.rawRepresentation.base64EncodedString())
            case "catalog-sign" where a.count == 4 && a[2] == "--key-env":
                let k = (ProcessInfo.processInfo.environment[a[3]] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !k.isEmpty else { throw fail(tr("\(a[3]) não está no ambiente", "\(a[3]) is not in the environment")) }
                let sig = try PluginCatalog.sign(try read(a[1]), privateKey: k)
                guard (try? sig.write(to: URL(fileURLWithPath: a[1] + ".sig"), options: .atomic)) != nil else {
                    throw fail(tr("não consegui gravar \(a[1]).sig", "could not write \(a[1]).sig"))
                }
                // sign accepted the key: prints its public half, for the workflow's verify
                if let raw = Data(base64Encoded: k), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                    print(key.publicKey.rawRepresentation.base64EncodedString())
                }
            case "catalog-verify" where a.count == 4 && a[2] == "--public":
                let c = try PluginCatalog.accept(try read(a[1]), signature: try read(a[1] + ".sig"), keys: [a[3]], lastSequence: nil)
                print("ok: sequence \(c.sequence), \(c.plugins.count) plug-in(s)")
            default:
                FileHandle.standardError.write(Data((usage + "\n").utf8)); return 2
            }
            return 0
        } catch { CLI.err(error.message); return 1 }
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
        if argv.first == "plugin", argv.count > 1, PluginPublishCLI.commands.contains(argv[1]) {
            return PluginPublishCLI.run(Array(argv.dropFirst()))
        }
        if let h = ArgvParser.help(argv) { print(h, terminator: ""); return 0 }   // `collie summon --help`, `collie help memory`
        if argv.first == "help" || argv.first == "--help" { print(usage(), terminator: ""); return 0 }
        if argv.isEmpty { FileHandle.standardError.write(Data(usage().utf8)); return 2 }
        let cmd: (command: String, args: [String: JSONValue])
        do { cmd = try await parse(argv) } catch { err(error.message); return 2 }
        if let e = RatchetCLI.refusal(cmd.command, cmd.args) { err(e); return 1 }   // F7a: before the measure runs
        do {
            let result = try await Client.call(cmd.command, cmd.args)
            if cmd.command == "android.install" && !json { return await followInstall(result) }   // prints the job lines itself
            if cmd.command == "design.engine.install" && !json { return await followInstall(result, status: "design.engine.status") }
            if cmd.command == "factory.doctor", case .object(let o) = result {   // U3: --json is the report; a layer below --min exits 1
                print(json ? jsonString(o["report"] ?? .null) + "\n" : render(cmd.command, result, json: false), terminator: "")
                return o["passed"] == .bool(false) ? 1 : 0
            }
            if cmd.command == "work.plan.lint", case .object(let o) = result {   // F5: refused exits 1
                print(render(cmd.command, result, json: json), terminator: "")
                return o["passed"] == .bool(false) ? 1 : 0
            }
            if cmd.command.hasPrefix("factory.ratchet.") {   // U5: worse (or improved, on check) exits 1
                // F6a/F7a: the daemon only measures; the baseline is written here, confined again (`RatchetCLI`)
                let (o, code) = RatchetCLI.handleRatchet(result, command: cmd.command, args: cmd.args,
                                                         cwd: FileManager.default.currentDirectoryPath, err: err)
                if o != .null { print(render(cmd.command, o, json: json), terminator: "") }
                return code
            }
            print(render(cmd.command, result, json: json), terminator: "")
            if case .object(let o) = result, case .bool(true)? = o["truncated"] { err("output truncated") }
            // the agent exists, its first prompt didn't get there: not a success, and a retried summon would say "already exists"
            if case .object(let o) = result, case .string(let e)? = o["promptError"] {
                err("agent started, but its first prompt was not delivered: \(e). Send it with `collie ask`")
                return 1
            }
            return 0
        } catch {
            err(error.message)
            return error.code == .daemonUnavailable ? 3 : 1
        }
    }

    /// `android.install` (or `design.engine.install`) replied `{job}`: one line per change of `status`'s job (polled each
    /// second) until it ends; 1 unless it ended `done`.
    static func followInstall(_ first: JSONValue, status: String = "android.status") async -> Int32 {
        func line(_ j: JSONValue?) -> (text: String, phase: String) {
            guard case .object(let o)? = j else { return ("", "") }
            func s(_ k: String) -> String? { if case .string(let v)? = o[k] { v } else { nil } }
            var t = s("phase") ?? ""
            if let i = s("item") { t += " \(i)" }
            if case .number(let n)? = o["percent"] { t += " \(Int(n))%" }
            if case .number(let b)? = o["bytes"], case .number(let tot)? = o["total"], tot > 0, s("phase") == "downloading" {
                t += " \(Int(b * 100 / tot))%"
            }
            if let e = s("error") { t += ": \(e)" }
            return (t, s("phase") ?? "")
        }
        var job: JSONValue?
        if case .object(let o) = first { job = o["job"] }
        var last = ""
        while true {
            let (text, phase) = line(job)
            if text != last { print(text); last = text }
            if ["done", "failed", "cancelled"].contains(phase) { return phase == "done" ? 0 : 1 }
            try? await Task.sleep(for: .seconds(1))
            do {
                guard case .object(let st) = try await Client.call(status, [:]) else { continue }
                job = st["job"]
                if job == nil { err("job lost (daemon restarted?)"); return 1 }
            } catch { err(error.message); return error.code == .daemonUnavailable ? 3 : 1 }
        }
    }

    /// An unknown command may be an external plug-in's: one `plugin.specs` fetch, then the parse again.
    static func parse(_ argv: [String]) async throws(ProtocolError) -> (command: String, args: [String: JSONValue]) {
        do { return try ArgvParser.parse(argv) } catch {
            guard error.message.hasPrefix("unknown command"), await Client.fetchPlugins() else { throw error }
            return try ArgvParser.parse(argv)
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
                if case .string(let m)? = o["model"] { line += "\tmodel=\(m)" }
                return line + "\n"
            }.joined()
        case ("check", .object(let o)) where o["model"] != nil:
            let s = "[model: \(str(o["model"]))]\n" + str(o["output"]); return s.hasSuffix("\n") ? s : s + "\n"
        case ("paddock.list", .array(let rows)):   // A2: one line each, "fábrica" beside a marked one's name
            return rows.map { if case .object(let o) = $0 { PaddockText.line(o) + "\n" } else { "" } }.joined()
        case ("paddock.status", .object(let o)), ("paddock.factory", .object(let o)): return PaddockText.line(o) + "\n"
        case ("model", .object(let o)): return str(o["model"]) + "\n" + (o["note"].map { "note: \(str($0))\n" } ?? "")
        case (_, .object(let o)) where o["output"] != nil:
            let s = str(o["output"]); return s.hasSuffix("\n") ? s : s + "\n"
        case ("device.screen", .object(let o)):
            return str(o["text"]) + "\n" + (o["tree"].map { "\n" + str($0) + "\n" } ?? "")
        case ("admin.spawn", .object(let o)): return str(o["id"]) + "\n"
        case ("plugin.install", .object(let o)):
            var s = tr("Instalado", "Installed") + " \(str(o["name"])) \(str(o["version"]))\n"
            if case .array(let lines)? = o["permissions"] { for l in lines { s += "  - \(str(l))\n" } }
            return s
        case (_, .null): return ""
        default: return jsonString(result) + "\n"
        }
    }
}
