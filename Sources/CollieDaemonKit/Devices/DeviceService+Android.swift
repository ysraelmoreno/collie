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
        // The device helper (H3), when ready: every command below tries it first and, when it is not ready, has gone
        // (it then stays in fallback for the session) or refuses, does what it did before (uiautomator, `input`).
        // The answers are the same either way.
        let helper = helpers[serial]
        func helped<T: Decodable>(_ r: HelperProtocol.Request, as _: T.Type) async -> T? {
            guard let line = await helper?.send(r) else { return nil }
            return try? HelperProtocol.decode(line, as: T.self)
        }
        func acked(_ r: HelperProtocol.Request) async -> Bool { await helped(r, as: HelperProtocol.Reply.self) != nil }
        /// A helper dump with an active window and nodes (an empty one sends the helper to fallback: H7).
        func helperDump() async -> HelperProtocol.Dump? { await helper?.dump() }
        /// `click` at `path` (the helper climbs to a clickable ancestor, else touches the node's center): true done,
        /// false `node gone` (the screen changed since the dump), nil not through the helper.
        func click(_ path: [Int]) async -> Bool? {
            guard let line = await helper?.send(.click(path: path)) else { return nil }
            do throws(ProtocolError) { _ = try HelperProtocol.decode(line, as: HelperProtocol.Reply.self); return true }
            catch { return error.message.contains("node gone") ? false : nil }
        }
        func tapAt(_ x: Int, _ y: Int) async throws(ProtocolError) -> JSONValue {
            if await acked(.tap(x: Double(x), y: Double(y))) { return .object([:]) }
            return try await shellInput(["tap", "\(x)", "\(y)"])
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
            let clock = ContinuousClock(), start = clock.now
            let nodes: [UINode], truncated: Bool, timing: [String: JSONValue]
            if let d = await helperDump() {
                let dumped = clock.now
                (nodes, truncated) = UITree.nodes(d)
                timing = ["adb": Self.ms(dumped - start), "parse": Self.ms(clock.now - dumped), "source": .string("helper")]
            } else {
                // one adb call: the XML comes straight on stdout; a device whose uiautomator cannot write /dev/tty prints
                // no hierarchy there, so fall back to the file dump (two calls)
                // ponytail: such a device pays the failed tty try on every dump; remember it per serial if one shows up
                var xml = AdbParsing.ttyDump(try await adb(["exec-out", "uiautomator", "dump", "/dev/tty"]).stdoutData)
                let via = xml == nil ? "file" : "tty"
                if xml == nil {
                    _ = try await adb(["shell", "uiautomator", "dump", "/sdcard/collie-ui.xml"])
                    xml = try await adb(["exec-out", "cat", "/sdcard/collie-ui.xml"]).stdoutData
                }
                let dumped = clock.now
                (nodes, truncated) = UITree.parse(xml ?? Data())
                timing = ["adb": Self.ms(dumped - start), "parse": Self.ms(clock.now - dumped), "dump": .string(via), "source": .string("uiautomator")]
            }
            try alive()
            refs[panel.id] = nodes
            let r = UITree.result(nodes, truncated: truncated, all: args["all"] == .bool(true))
            guard Self.timing(args), case .object(var o) = r else { return r }
            o["timingMs"] = .object(timing)
            return .object(o)
        case "device.tap":
            if let ref = args["ref"].flatMap({ if case .string(let s) = $0 { s } else { nil } }) {
                guard var n = refs[panel.id]?.first(where: { $0.ref == ref }) else {
                    throw ProtocolError(code: .notFound, message: "Unknown ref \(ref); run device.ui first")
                }
                // semantic click on a node the helper read; a stale path: one fresh read, the same node found again
                // (class, text, desc and id), one more click. Still gone, or not clickable by the helper: tap its center.
                if let path = n.path, var done = await click(path) {
                    if !done, let d = await helperDump() {
                        let fresh = UITree.nodes(d).nodes
                        try alive()
                        refs[panel.id] = fresh
                        if let m = fresh.first(where: { $0.cls == n.cls && $0.text == n.text && $0.desc == n.desc && $0.id == n.id }), let p = m.path {
                            n = m; done = await click(p) ?? false
                        }
                    }
                    if done { return .object([:]) }
                }
                return try await tapAt(n.center.x, n.center.y)
            }
            guard let x = try Self.int(args, "x"), let y = try Self.int(args, "y") else {
                throw ProtocolError(code: .invalidArgs, message: "device.tap needs x and y, or --ref")
            }
            return try await tapAt(x, y)
        case "device.swipe":
            let c = try ["x1", "y1", "x2", "y2"].map { k throws(ProtocolError) in
                guard let v = try Self.int(args, k) else { throw ProtocolError(code: .invalidArgs, message: "Missing argument '\(k)'") }
                return v
            }
            let ms = try Self.int(args, "ms", 1...10_000) ?? 300
            if await acked(.swipe(x1: Double(c[0]), y1: Double(c[1]), x2: Double(c[2]), y2: Double(c[3]), ms: ms)) { return .object([:]) }
            return try await shellInput(["swipe"] + c.map { "\($0)" } + ["\(ms)"])
        case "device.text":
            guard case .string(let t)? = args["text"], !t.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'text'") }
            let arg = try AdbParsing.inputTextArg(t)   // checked first: the same invalidArgs with or without the helper
            // ponytail: the helper sets the focused field's text (ACTION_SET_TEXT) where `input text` types at the cursor;
            // same on the empty fields agents fill. No focused field: `input text`, as before.
            if await acked(.text(t)) { return .object([:]) }
            return try await shellInput(["text", arg])
        case "device.key":
            guard case .string(let k)? = args["key"], let code = AndroidKeys.keycode(named: k) else {
                throw ProtocolError(code: .invalidArgs, message: "Unknown key")
            }
            // back, home and recents (app switch) as global actions; every other key stays a keyevent
            if let g = [4: "back", 3: "home", 187: "recents"][code], await acked(.global(g)) { return .object([:]) }
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
    private var liteAvdDir: URL { avdDir(LiteAvd.name) }

    /// `<ANDROID_AVD_HOME or ~/.android/avd>/<name>.avd`.
    func avdDir(_ name: String) -> URL {
        let base = emulatorEnv["ANDROID_AVD_HOME"] ?? NSHomeDirectory() + "/.android/avd"
        return URL(fileURLWithPath: base).appendingPathComponent("\(name).avd")
    }

    /// The panel frame of an emulator running AVD `name`, from `hw.device.name` in its config.ini; an unreadable file is `phone`.
    func avdFrame(_ name: String) -> DeviceFrame.Kind {
        let ini = try? String(contentsOf: avdDir(name).appendingPathComponent("config.ini"), encoding: .utf8)
        return DeviceFrame.android(hwDeviceName: ini.flatMap(DeviceFrame.hwDeviceName(configIni:)), emulator: true)
    }

    /// Frame of an adb serial: an emulator's AVD name comes from `runningAvds` (unnamed: `phone`); anything else is `bare`.
    func androidFrame(serial: String) async -> DeviceFrame.Kind {
        guard serial.hasPrefix("emulator-") else { return .bare }
        var known: [String: String] = [:]
        let byName = await runningAvds(known: &known, deadline: .now + .seconds(5)) ?? [:]
        guard let name = byName.first(where: { $0.value.serial == serial })?.key else { return .phone }
        return avdFrame(name)
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

/// `device screen --ocr|--no-ocr|--region x1,y1,x2,y2`: O2 rule 5 (explicit) over the tree's rules 1-3.
struct OCRMode: Sendable {
    var forced = false, off = false, region: CGRect?
    static let auto = OCRMode()
    /// The rule that fires (`--timing`'s `trigger`: labels|coverage|opaque, explicit for --ocr/--region), nil: no OCR.
    func trigger(_ nodes: [UINode]) -> String? {
        if off { return nil }
        return forced ? "explicit" : OCR.trigger(nodes)?.rawValue
    }
}

/// One OCR pass: the merged nodes (empty on a black/uniform screen or an empty read), nil when the OCR is unavailable
/// (no provider, no screenshot, provider error); its time and the rule that fired.
struct OCRRead: Sendable {
    let nodes: [UINode]?, took: Duration, trigger: String
}

extension DeviceService {
    /// Parses the OCR flags; `--region` implies `--ocr` (it asks to read that rectangle) and clashes with `--no-ocr`.
    static func ocrMode(_ a: [String: JSONValue]) throws(ProtocolError) -> OCRMode {
        func flag(_ k: String) -> Bool { a[k] == .bool(true) || a[k] == .string("true") }
        var m = OCRMode(forced: flag("ocr"), off: flag("no-ocr"))
        switch a["region"] {
        case nil, .null?: break
        case .string(let s)?:
            let v = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4, v[0] >= 0, v[1] >= 0, v[2] > v[0], v[3] > v[1] else {
                throw ProtocolError(code: .invalidArgs, message: "--region takes x1,y1,x2,y2 (Android pixels, iOS points, x2 > x1, y2 > y1)")
            }
            m.region = CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]); m.forced = true
        default: throw ProtocolError(code: .invalidArgs, message: "--region takes x1,y1,x2,y2")
        }
        if m.off && m.forced { throw ProtocolError(code: .invalidArgs, message: "--no-ocr cannot go with --ocr or --region") }
        return m
    }

    /// The screen's PNG, in memory (never written).
    func screencap(_ serial: String) async throws(ProtocolError) -> Data {
        let r = try await tool().run(["exec-out", "screencap", "-p"], serial: serial, timeout: .seconds(30))
        guard !r.truncated, AdbParsing.pngSize(r.stdoutData) != nil else { throw ProtocolError(code: .internal, message: "screencap did not return a PNG") }
        return r.stdoutData
    }

    /// O1/O3/O5: screenshot, black check, `--region` crop, OCR (accurate), merge with `tree`. Never throws: the screen
    /// falls back to the tree. ponytail: always `accurate` (the fallback's default); a `--ocr fast` when someone needs it.
    /// A3: on iOS the tree, `region` and taps are points and the screenshot pixels (`simShot`'s scale): the region is
    /// scaled up for the crop and the boxes down before they become nodes. Android: scale 1.
    func ocrRead(panel: Panel, serial: String, tree: [UINode], trigger: String, region: CGRect?) async -> OCRRead {
        let start = ContinuousClock.now
        func done(_ n: [UINode]?) -> OCRRead { OCRRead(nodes: n, took: ContinuousClock.now - start, trigger: trigger) }
        guard let ocr else { return done(nil) }
        let shot: (png: Data, scale: CGFloat)?
        if panel.state["platform"] == .string("ios") { shot = await simShot(serial, points: simPoints[panel.id]) }
        else { shot = (try? await screencap(serial)).map { ($0, 1) } }
        guard let shot else { return done(nil) }
        var png = shot.png
        let scale = shot.scale
        if OCRImage.uniform(png) { return done([]) }   // black (FLAG_SECURE) or flat: nothing to read
        var origin = CGPoint.zero
        if let region {
            guard let cut = OCRImage.crop(png, to: region.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return done([]) }
            png = cut.png; origin = cut.rect.origin
        }
        guard let items = try? await ocr.recognize(png: png, level: .accurate, languages: ocrLanguages) else { return done(nil) }
        let toPoints = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        return done(OCR.nodes(items.map { var i = $0; i.box = i.box.offsetBy(dx: origin.x, dy: origin.y).applying(toPoints); return i }, tree: tree))
    }
}
