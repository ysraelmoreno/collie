import Foundation
import OrqCore
import OrqDevice
import OrqProtocol

/// The `device.*` commands of an iOS Simulator panel (`serial` is the UDID): simctl for the screen, logs, installs and
/// launches; AXe for input and the UI tree. Coordinates are points, what AXe and `describe-ui` use.
extension DeviceService {
    func simulators() async throws(ProtocolError) -> [SimDevice] {
        SimCtl.devices(try await sim.simctl(["list", "devices", "-j"], timeout: .seconds(15), cap: 8 << 20).stdoutData)
    }

    /// A simulator not booted yet is booted and waited for, within 120 s. `bootstatus -b` boots it itself: no separate
    /// `boot`, which fails ("current state: Booting") when two opens race.
    func boot(_ d: SimDevice) async throws(ProtocolError) {
        guard d.state != "booted" else { return }
        _ = try await sim.simctl(["bootstatus", d.udid, "-b"], timeout: .seconds(120))
    }

    func runIOS(_ command: String, panel: Panel, udid: String, args: [String: JSONValue], cwd: String?) async throws(ProtocolError) -> JSONValue {
        let sim = sim
        guard try await simulators().contains(where: { $0.udid == udid && $0.state == "booted" }) else {
            throw ProtocolError(code: .notFound, message: "Simulator \(udid) is not booted")
        }
        let timeout = Duration.seconds(PluginRegistry.command(command)?.1.timeoutSeconds ?? 30)
        func axe(_ a: [String], cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult {
            try await sim.axe(a, udid: udid, timeout: timeout, cap: cap)
        }
        func input(_ a: [String]) async throws(ProtocolError) -> JSONValue {
            _ = try await axe(a); return .object([:])
        }
        // AXe sometimes fails once ("No translation object returned for simulator"); a second try works
        func describe() async throws(ProtocolError) -> (nodes: [UINode], truncated: Bool, screen: CGSize?) {
            var tree = AXeTree.parse(Data())
            for attempt in 0..<2 {
                do { tree = AXeTree.parse(try await axe(["describe-ui"], cap: 32 << 20).stdoutData) } catch where attempt == 0 { continue }
                if tree.screen != nil { break }
            }
            return tree
        }
        switch command {
        case "device.screenshot":
            let file = screens.appendingPathComponent("\(panel.id.uuidString)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            do { try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true) }
            catch { throw ProtocolError(code: .internal, message: "cannot write screenshot: \(error.localizedDescription)") }
            _ = try await sim.simctl(["io", udid, "screenshot", file.path], timeout: timeout)
            do { try alive(panel) } catch { try? FileManager.default.removeItem(at: file); throw error }
            guard let data = try? Data(contentsOf: file), let size = AdbParsing.pngSize(data) else {
                try? FileManager.default.removeItem(at: file)
                throw ProtocolError(code: .internal, message: "simctl screenshot did not write a PNG")
            }
            var out: [String: JSONValue] = ["path": .string(file.path), "width": .number(Double(size.width)), "height": .number(Double(size.height))]
            // tap/swipe take points, the PNG is pixels: say how to convert (omitted when AXe cannot tell the point size)
            if let pt = (try? await describe())?.screen, pt.width >= 1, pt.height >= 1 {
                out["scale"] = .number(Double(size.width) / pt.width)
                out["pointWidth"] = .number(pt.width); out["pointHeight"] = .number(pt.height)
            }
            return .object(out)
        case "device.ui":
            let tree = try await describe()
            guard tree.screen != nil else { throw ProtocolError(code: .internal, message: "axe describe-ui returned no UI tree") }
            try alive(panel)
            refs[panel.id] = tree.nodes
            return .object(["tree": .string(UITree.lines(tree.nodes)), "truncated": .bool(tree.truncated)])
        case "device.tap":
            if let ref = args["ref"].flatMap({ if case .string(let s) = $0 { s } else { nil } }) {
                guard let n = refs[panel.id]?.first(where: { $0.ref == ref }) else {
                    throw ProtocolError(code: .notFound, message: "Unknown ref \(ref); run device.ui first")
                }
                return try await input(["tap", "-x", "\(n.center.x)", "-y", "\(n.center.y)"])
            }
            guard let x = try Self.int(args, "x"), let y = try Self.int(args, "y") else {
                throw ProtocolError(code: .invalidArgs, message: "device.tap needs x and y, or --ref")
            }
            return try await input(["tap", "-x", "\(x)", "-y", "\(y)"])
        case "device.swipe":
            let c = try ["x1", "y1", "x2", "y2"].map { k throws(ProtocolError) in
                guard let v = try Self.int(args, k) else { throw ProtocolError(code: .invalidArgs, message: "Missing argument '\(k)'") }
                return "\(v)"
            }
            let ms = try Self.int(args, "ms", 1...10_000) ?? 300
            return try await input(["swipe", "--start-x", c[0], "--start-y", c[1], "--end-x", c[2], "--end-y", c[3],
                                    "--duration", "\(Double(ms) / 1000)"])
        case "device.text":
            guard case .string(let t)? = args["text"], !t.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'text'") }
            try SimText.validate(t)
            return try await input(["type", "--", t])   // `--`: a text starting with "-" is text, not an option
        case "device.key":
            guard case .string(let k)? = args["key"] else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'key'") }
            if let b = IOSKeys.button(named: k) { return try await input(["button", b]) }
            guard let u = IOSKeys.usage(named: k) else {
                throw ProtocolError(code: .invalidArgs,
                    message: "Key '\(k)' has no iOS equivalent (Enter, Escape, Backspace, Tab, Space, arrows, Home, Lock or a HID usage 0-255)")
            }
            return try await input(["key", "\(u)"])
        case "device.logcat":
            let n = try Self.int(args, "lines", 1...2000) ?? 200
            // the cap keeps the oldest part of the output: when a busy simulator hits it, ask for less time so the tail is recent
            var r = try await sim.simctl(["spawn", udid, "log", "show", "--last", "5m", "--style", "compact"], timeout: timeout, cap: logCap)
            if r.truncated {
                r = try await sim.simctl(["spawn", udid, "log", "show", "--last", "30s", "--style", "compact"], timeout: timeout, cap: logCap)
            }
            var lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if case .string(let g)? = args["grep"], !g.isEmpty { lines = lines.filter { $0.contains(g) } }   // substring, no regex
            while lines.last?.isEmpty == true { lines.removeLast() }
            return .object(["text": .string(lines.suffix(n).joined(separator: "\n")), "truncated": .bool(r.truncated)])
        case "device.install":
            guard case .string(let path)? = args["path"], !path.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'path'") }
            let url = URL(fileURLWithPath: path, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }).standardizedFileURL
            guard url.pathExtension.lowercased() == "app" else { throw ProtocolError(code: .invalidArgs, message: "iOS installs .app bundles") }
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue else {
                throw ProtocolError(code: .notFound, message: "No such app bundle: \(url.path)")
            }
            let out = try await sim.simctl(["install", udid, url.path], timeout: timeout).stdout
            return .object(["output": .string(out.trimmingCharacters(in: .whitespacesAndNewlines))])
        case "device.launch":
            if let a = args["activity"], a != .null { throw ProtocolError(code: .invalidArgs, message: "--activity is Android-only") }
            guard case .string(let id)? = args["package"], !id.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'package'") }
            let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
            guard !id.hasPrefix("-"), id.unicodeScalars.allSatisfy(ok.contains) else {   // a leading "-" would be a simctl option
                throw ProtocolError(code: .invalidArgs, message: "'package' must be a bundle id (letters, digits, '.' and '-')")
            }
            _ = try await sim.simctl(["launch", udid, id], timeout: timeout)
            await emit(panel.id, "device.app_launched", .object(["serial": .string(udid), "package": .string(id)]))
            return .object([:])
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
        }
    }
}
