import Foundation
import CollieCore
import CollieDevice
import CollieProtocol

/// An installed AVD; `serial` is the `emulator-NNNN` it already runs as, nil when off.
struct Avd: Sendable, Equatable { var name: String; var serial: String? }

/// The `device.*` commands of an Android panel, through adb (plan 1F; moved here unchanged when iOS arrived).
extension DeviceService {
    /// Installed AVDs, each tagged with the emulator serial it already runs as (any adb state: a booting one counts).
    /// No emulator tool or a failing `-list-avds`: `[]`. A running emulator whose name can't be read stays unnamed
    /// (its AVD then looks off). Bounded to ~10 s so a slow emulator tool never fails `device.list`.
    func avds() async -> [Avd] {
        let deadline = ContinuousClock.now + .seconds(10)
        guard let u = emulator(), FileManager.default.isExecutableFile(atPath: u.path),
              let names = try? await Emulator(url: u).listAvds(timeout: .seconds(5), env: emulatorEnv), !names.isEmpty else { return [] }
        var k: [String: String] = [:]
        let byName = await runningAvds(known: &k, deadline: deadline) ?? [:]
        return names.map { Avd(name: $0, serial: byName[$0]?.serial) }
    }

    /// Emulators adb lists, in any state, by AVD name; `known` (serial → name) skips serials already asked. Every adb
    /// call gets what is left before `deadline` (at most 5 s); none starts after it. nil: adb missing, `devices -l` failing.
    func runningAvds(known: inout [String: String], deadline: ContinuousClock.Instant) async -> [String: AdbDevice]? {
        func left() -> Duration? { let l = min(.seconds(5), deadline - .now); return l > .zero ? l : nil }
        guard let tool = try? await tool(), let t = left(),
              let r = try? await tool.run(["devices", "-l"], serial: nil, timeout: t) else { return nil }
        let emus = AdbParsing.devices(r.stdout).filter { $0.serial.hasPrefix("emulator-") }
        // ponytail: sequential, one short adb call per emulator; fine for the few that run at once
        for e in emus where known[e.serial] == nil {
            guard let t = left() else { break }
            // the console answers while the emulator is still `offline` (booting); the reply is the name and an `OK` line, in either order
            let lines = (try? await tool.run(["emu", "avd", "name"], serial: e.serial, timeout: t))?.stdout
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            if let n = lines.first(where: { !$0.isEmpty && $0 != "OK" }) { known[e.serial] = n }
        }
        return Dictionary(emus.compactMap { e in known[e.serial].map { ($0, e) } }, uniquingKeysWith: { a, b in a.state == "device" ? a : b })
    }

    /// The `emulator-NNNN` serial of AVD `name`, booted first when it is off (shared by concurrent callers). The emulator
    /// is left running whatever happens: a timeout, a closed panel or a daemon stop never shuts it down.
    func bootAvd(_ name: String) async throws(ProtocolError) -> String {
        let t: Task<String, Error>
        if let cur = boots[name] { t = cur } else {
            t = Task { defer { self.boots[name] = nil }; return try await self.bootOnce(name) }
            boots[name] = t
        }
        do { return try await t.value } catch let e as ProtocolError { throw e } catch {
            throw ProtocolError(code: .internal, message: "\(error)")
        }
    }

    private func bootOnce(_ name: String) async throws(ProtocolError) -> String {
        // one deadline for the whole call, each adb call capped by what is left: the timeout lands before panel.open's
        let deadline = ContinuousClock.now + emulatorBoot
        func left(_ cap: Duration = .seconds(5)) -> Duration { max(.milliseconds(500), min(cap, deadline - .now)) }
        guard let u = emulator(), FileManager.default.isExecutableFile(atPath: u.path) else { throw Emulator.missing }
        let names = try await Emulator(url: u).listAvds(timeout: left(.seconds(15)), env: emulatorEnv)
        guard names.contains(name) else {
            throw ProtocolError(code: .invalidArgs, message: "Unknown AVD '\(name)' (\(names.isEmpty ? "none installed" : names.joined(separator: ", ")))")
        }
        let tool = try await tool()
        var known: [String: String] = [:]
        var running = await runningAvds(known: &known, deadline: deadline)
        if running == nil, await tool.startServer() { running = await runningAvds(known: &known, deadline: deadline) }   // adb was down: an AVD already up must not launch twice
        var pid: pid_t?
        if let e = running?[name] {
            if e.state == "device" { return e.serial }
            // still booting (`offline`): a second launch would be refused, so only wait for it
        } else {
            let log = runDir.appendingPathComponent("emulator-\(name).log")
            try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            let sdk = u.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            pid = try await Emulator(url: u).launch(avd: name, log: log, sdkRoot: sdk, env: emulatorEnv)
        }
        while true {
            if let pid, kill(pid, 0) != 0 {
                let log = runDir.appendingPathComponent("emulator-\(name).log")
                let text: String = (try? await UnixSocketClient.offPool { try String(contentsOf: log, encoding: .utf8) }) ?? ""
                let tail = text.split(whereSeparator: \.isNewline).suffix(5).joined(separator: "\n")
                throw ProtocolError(code: .internal, message: "Emulator '\(name)' exited: \(tail.suffix(500))")
            }
            if let e = await runningAvds(known: &known, deadline: deadline)?[name], e.state == "device",
               (try? await tool.run(["shell", "getprop", "sys.boot_completed"], serial: e.serial, timeout: left()))?.stdout
                   .trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return e.serial }
            guard ContinuousClock.now < deadline else {
                throw ProtocolError(code: .timeout, message: "Emulator '\(name)' did not finish booting in \(emulatorBoot.components.seconds) s (it is left running)")
            }
            do { try await Task.sleep(for: .seconds(1)) } catch {
                throw ProtocolError(code: .internal, message: "Emulator '\(name)' boot wait was cancelled (it is left running)")
            }
        }
    }

    func runAndroid(_ command: String, panel: Panel, serial: String, args: [String: JSONValue], cwd: String?) async throws(ProtocolError) -> JSONValue {
        let tool = try await tool()
        func alive() throws(ProtocolError) { try self.alive(panel) }
        guard try await devices().contains(where: { $0.serial == serial && $0.state == "device" }) else {
            throw ProtocolError(code: .notFound, message: "Device \(serial) is offline")
        }
        let timeout = Duration.seconds(PluginRegistry.command(command)?.1.timeoutSeconds ?? 30)
        func adb(_ a: [String], cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult {
            try await tool.run(a, serial: serial, timeout: timeout, cap: cap)
        }
        func shellInput(_ a: [String]) async throws(ProtocolError) -> JSONValue {
            _ = try await adb(["shell", "input"] + a); return .object([:])
        }
        switch command {
        case "device.screenshot":
            let r = try await adb(["exec-out", "screencap", "-p"])
            try alive()
            guard !r.truncated, let size = AdbParsing.pngSize(r.stdoutData) else {
                throw ProtocolError(code: .internal, message: "screencap did not return a PNG")
            }
            let file = screens.appendingPathComponent("\(panel.id.uuidString)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            do {
                try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
                try r.stdoutData.write(to: file)
            } catch { throw ProtocolError(code: .internal, message: "cannot write screenshot: \(error.localizedDescription)") }
            return .object(["path": .string(file.path), "width": .number(Double(size.width)), "height": .number(Double(size.height))])
        case "device.ui":
            _ = try await adb(["shell", "uiautomator", "dump", "/sdcard/collie-ui.xml"])
            let xml = try await adb(["exec-out", "cat", "/sdcard/collie-ui.xml"])
            let (nodes, truncated) = UITree.parse(xml.stdoutData)
            try alive()
            refs[panel.id] = nodes
            return UITree.result(nodes, truncated: truncated, all: args["all"] == .bool(true))
        case "device.tap":
            if let ref = args["ref"].flatMap({ if case .string(let s) = $0 { s } else { nil } }) {
                guard let n = refs[panel.id]?.first(where: { $0.ref == ref }) else {
                    throw ProtocolError(code: .notFound, message: "Unknown ref \(ref); run device.ui first")
                }
                return try await shellInput(["tap", "\(n.center.x)", "\(n.center.y)"])
            }
            guard let x = try Self.int(args, "x"), let y = try Self.int(args, "y") else {
                throw ProtocolError(code: .invalidArgs, message: "device.tap needs x and y, or --ref")
            }
            return try await shellInput(["tap", "\(x)", "\(y)"])
        case "device.swipe":
            let c = try ["x1", "y1", "x2", "y2"].map { k throws(ProtocolError) in
                guard let v = try Self.int(args, k) else { throw ProtocolError(code: .invalidArgs, message: "Missing argument '\(k)'") }
                return "\(v)"
            }
            return try await shellInput(["swipe"] + c + ["\(try Self.int(args, "ms", 1...10_000) ?? 300)"])
        case "device.text":
            guard case .string(let t)? = args["text"], !t.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'text'") }
            return try await shellInput(["text", try AdbParsing.inputTextArg(t)])
        case "device.key":
            guard case .string(let k)? = args["key"], let code = AndroidKeys.keycode(named: k) else {
                throw ProtocolError(code: .invalidArgs, message: "Unknown key")
            }
            return try await shellInput(["keyevent", "\(code)"])
        case "device.logcat":
            let n = try Self.int(args, "lines", 1...2000) ?? 200
            var lines = try await adb(["logcat", "-d", "-t", "\(n)"]).stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if case .string(let g)? = args["grep"], !g.isEmpty { lines = lines.filter { $0.contains(g) } }   // substring, no regex
            while lines.last?.isEmpty == true { lines.removeLast() }
            return .object(["text": .string(lines.joined(separator: "\n"))])
        case "device.install":
            guard case .string(let path)? = args["path"], !path.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'path'") }
            let url = URL(fileURLWithPath: path, relativeTo: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }).standardizedFileURL
            guard url.pathExtension.lowercased() == "apk" else { throw ProtocolError(code: .invalidArgs, message: "Only .apk files can be installed") }
            guard FileManager.default.fileExists(atPath: url.path) else { throw ProtocolError(code: .notFound, message: "No such file: \(url.path)") }
            let out = try await adb(["install", "-r", url.path]).stdout
            guard out.contains("Success") else { throw ProtocolError(code: .internal, message: "install failed: \(out.prefix(500))") }
            return .object(["output": .string(out.trimmingCharacters(in: .whitespacesAndNewlines))])
        case "device.launch":
            // package/activity reach the device's shell unquoted: only identifier characters get through
            // ponytail: no `$` in activities, so nested classes need the app's launcher path (monkey) instead of --activity
            let ident = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.")
            func word(_ k: String) throws(ProtocolError) -> String? {
                guard case .string(let s)? = args[k] else { return nil }
                guard !s.isEmpty, s.unicodeScalars.allSatisfy(ident.contains) else {
                    throw ProtocolError(code: .invalidArgs, message: "'\(k)' may only contain letters, digits, '_' and '.'")
                }
                return s
            }
            guard let pkg = try word("package") else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'package'") }
            // No --activity: an app may have several LAUNCHER activities (e.g. leakcanary's), and monkey then opens none (exit 251).
            // So list them and start the first; monkey only when the list is unavailable or empty.
            var activity = try word("activity")
            if activity == nil, let list = try? await adb(["shell", "cmd", "package", "query-activities", "--brief",
                                                            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", pkg]).stdout {
                let comp = ident.union(CharacterSet(charactersIn: "/"))
                activity = list.split(whereSeparator: \.isWhitespace).lazy
                    .filter { $0.hasPrefix("\(pkg)/") && $0.unicodeScalars.allSatisfy(comp.contains) }
                    .map { String($0.dropFirst(pkg.count + 1)) }.first { !$0.isEmpty }
            }
            let out: String
            do {
                out = try await adb(activity.map { ["shell", "am", "start", "-n", "\(pkg)/\($0)"] }
                                    ?? ["shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"]).stdout
            } catch { out = "Error" }
            guard !out.contains("Error"), !out.contains("monkey aborted") else {
                throw ProtocolError(code: .internal, message: activity.map { "could not start \(pkg)/\($0); check the activity name with --activity" }
                                    ?? "could not launch \(pkg): no launcher activity found; is it installed? Pass --activity to pick one")
            }
            await emit(panel.id, "device.app_launched", .object(["serial": .string(serial), "package": .string(pkg)]))
            return .object(activity.map { ["activity": .string($0)] } ?? [:])
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(command)'")
        }
    }
}

/// The lightweight `collie-lite` AVD (pure pieces in `LiteAvd`).
extension DeviceService {
    private var liteAvdDir: URL {
        let base = emulatorEnv["ANDROID_AVD_HOME"] ?? NSHomeDirectory() + "/.android/avd"
        return URL(fileURLWithPath: base).appendingPathComponent("\(LiteAvd.name).avd")
    }

    /// Creates `collie-lite` with the best installed arm64 image, then applies `LiteAvd.overrides` to its config.ini.
    /// An existing AVD is not recreated, only its config is re-merged (`created: "false"`).
    func createLiteAvd() async throws(ProtocolError) -> [String: String] {
        guard let mgr = avdManager() else { throw AvdManager.missing }
        guard let u = emulator(), FileManager.default.isExecutableFile(atPath: u.path) else { throw Emulator.missing }
        let sdk = u.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        guard let image = LiteAvd.pickImage(LiteAvd.installedImages(sdkRoot: sdk)) else {
            throw ProtocolError(code: .unavailable, message: "No arm64 google_apis system image installed. In Android Studio open SDK Manager "
                + "and install \"system-images;android-<api>;google_apis;arm64-v8a\" (for example android-37.0).")
        }
        let dir = liteAvdDir, config = dir.appendingPathComponent("config.ini")
        let existed = FileManager.default.fileExists(atPath: config.path)
        var env = emulatorEnv
        env["ANDROID_AVD_HOME"] = dir.deletingLastPathComponent().path   // avdmanager writes where existence is checked
        env["ANDROID_SDK_ROOT"] = sdk.path   // the root the image was picked from, as Emulator.launch forces
        if !existed {
            let r = try await mgr.run(["create", "avd", "-n", LiteAvd.name, "-k", image, "-d", "pixel", "--force"], env: env, timeout: .seconds(60))
            guard r.status == 0 else { throw ProtocolError(code: .internal, message: "avdmanager create failed: \(r.stderr.prefix(500))") }
        }
        do {
            let old = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            try LiteAvd.mergeConfig(old, LiteAvd.overrides).write(to: config, atomically: true, encoding: .utf8)
        } catch { throw ProtocolError(code: .internal, message: "cannot write \(config.path): \(error.localizedDescription)") }
        return ["name": LiteAvd.name, "path": dir.path, "image": image, "created": existed ? "false" : "true"]
    }

    /// Deletes `collie-lite`; no AVD, nothing to do.
    func removeLiteAvd() async throws(ProtocolError) {
        guard FileManager.default.fileExists(atPath: liteAvdDir.appendingPathComponent("config.ini").path) else { return }
        guard let mgr = avdManager() else { throw AvdManager.missing }
        var env = emulatorEnv
        env["ANDROID_AVD_HOME"] = liteAvdDir.deletingLastPathComponent().path
        if let u = emulator() {
            env["ANDROID_SDK_ROOT"] = u.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
        }
        let r = try await mgr.run(["delete", "avd", "-n", LiteAvd.name], env: env, timeout: .seconds(60))
        guard r.status == 0 else { throw ProtocolError(code: .internal, message: "avdmanager delete failed: \(r.stderr.prefix(500))") }
    }
}
