import Foundation
import CollieCore
import CollieDevice
import CollieProtocol

/// Runs the `device.*` agent commands: through adb for an Android panel, simctl + AXe for an iOS Simulator one
/// (`state["platform"]`, "android" when absent). Per-panel state (UI refs) lives here; the panel's serial is in
/// its `state`. Screenshots go to `<root>/screens/<panelId>-<epochMs>.png` and die with the panel.
/// While a device panel is open its serial is watched (`watch(panels:)`): connection changes and crashes become events.
/// A panel's screen is one `ViewerSession` (`DeviceSession` on Android, `SimSession` on iOS), shared by its `ui.device` viewers (`attach`).
actor DeviceService {
    private let root: URL
    let runDir: URL
    private let pollInterval: Duration
    private let adb: @Sendable () -> URL?
    private let xcrun: URL
    private let axe: @Sendable () -> URL?
    let emulator: @Sendable () -> URL?
    /// How long a launched emulator may take to show up as booted.
    let emulatorBoot: Duration
    /// The launched emulator's environment (the daemon's minus `COLLIE_*`: no tokens or socket).
    let emulatorEnv: [String: String]
    /// `avdmanager` + Java, looked up per use (the real env keeps `COLLIE_AVDMANAGER` / `COLLIE_JAVA_HOME`, which `emulatorEnv` strips).
    let avdManager: @Sendable () -> AvdManager?
    /// AVD name → its boot in progress (`bootAvd`): concurrent opens share it; it leaves when done.
    var boots: [String: Task<String, Error>] = [:]
    let emit: @Sendable (UUID, String, JSONValue) async -> Void
    var refs: [UUID: [UINode]] = [:]
    /// The last `device.screen` per panel, for its `changed`.
    var lastScreen: [UUID: Screen] = [:]
    /// iOS: the screen in points of the last `device.ui` per panel (AXe), to map the OCR's pixels back to points (A3).
    var simPoints: [UUID: CGSize] = [:]
    /// Panels closed so far: a command that was awaiting adb when its panel closed must not write anything afterwards.
    /// ponytail: grows by one UUID per closed device panel for the daemon's life; fine at this scale.
    var closed: Set<UUID> = []

    /// Watched panels → their serial; the last seen online state per watched serial (nil: not polled yet).
    private var watched: [UUID: String] = [:]
    private var online: [String: Bool] = [:]
    private var poller: Task<Void, Never>?
    /// iOS Simulator panels → UDID; last seen booted state per UDID; crash reports seen (oldest first, ≤ 1000); when watching began.
    private var watchedIOS: [UUID: String] = [:]
    private var booted: [String: Bool] = [:]
    private var seenIPS: [String] = []
    private var iosSince = Date()
    private let crashReports: URL
    /// Most bytes of `log show` kept (iOS `device.logcat`).
    let logCap: Int
    /// One crash watcher (`adb logcat -b crash`) per online watched serial; `id` tells a restarted one from the old one.
    private struct CrashWatch {
        let id = UUID()
        var proc: LongProcess?
        var log = CrashLog()
        var lineGen = 0
        var backoff: Duration = .seconds(2)
        var startedAt = ContinuousClock.now
        var starting = false
    }
    private var crash: [String: CrashWatch] = [:]

    private let scrcpyServer: URL?
    /// How long a session outlives its last viewer.
    private let grace: Duration
    private var sessions: [UUID: any ViewerSession] = [:]
    /// The accessibility helper APK to install (`DeviceHelper`); nil: not bundled.
    let helperApk: @Sendable () -> URL?
    /// One helper per Android serial, and the panels that started theirs (panel → serial).
    var helpers: [String: DeviceHelper] = [:]
    var helperPanels: [UUID: String] = [:]
    private var idle: [UUID: Task<Void, Never>] = [:]
    /// The OCR fallback of `device screen` (`VisionOCR` in collied); nil: none, poor trees say `ocr: unavailable`.
    let ocr: (any OCRProvider)?
    let ocrLanguages: [String]

    init(root: URL, runDir: URL, pollInterval: Duration = .seconds(2), scrcpyServer: URL? = nil, grace: Duration = .seconds(5),
         adb: @escaping @Sendable () -> URL?, emulator: @escaping @Sendable () -> URL? = { nil }, emulatorBoot: Duration = .seconds(180),
         emulatorEnv: [String: String]? = nil,
         avdManager: @escaping @Sendable () -> AvdManager? = { AvdManager.locate(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory()) },
         xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
         axe: @escaping @Sendable () -> URL? = { nil }, crashReports: URL = Simulator.defaultCrashReports, logCap: Int = 8 << 20,
         helperApk: @escaping @Sendable () -> URL? = { nil },
         ocr: (any OCRProvider)? = nil, ocrLanguages: [String] = VisionOCR.defaultLanguages,
         emit: @escaping @Sendable (UUID, String, JSONValue) async -> Void) {
        self.root = root; self.runDir = runDir; self.pollInterval = pollInterval; self.adb = adb; self.emulator = emulator; self.emulatorBoot = emulatorBoot; self.emit = emit; self.avdManager = avdManager
        self.emulatorEnv = emulatorEnv ?? ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("COLLIE_") }
        self.xcrun = xcrun; self.axe = axe; self.crashReports = crashReports; self.logCap = logCap
        self.scrcpyServer = scrcpyServer; self.grace = grace; self.helperApk = helperApk
        self.ocr = ocr; self.ocrLanguages = ocrLanguages
    }

    var screens: URL { root.appendingPathComponent("screens") }
    /// AXe is looked up per use: it may be installed while the daemon runs.
    var sim: Simulator { Simulator(xcrun: xcrun, axe: axe()) }

    /// The session's one `adb start-server` (shared by concurrent first callers; retried after a failure).
    private var server: Task<Bool, Never>?

    /// The adb tool, with the server started (`Adb.startServer`) before its first use in this daemon session.
    func tool() async throws(ProtocolError) -> Adb {
        guard let u = adb(), FileManager.default.isExecutableFile(atPath: u.path) else { throw Adb.missing }
        let tool = Adb(url: u), t = server ?? Task { await tool.startServer() }
        server = t
        guard await t.value else {
            if server == t { server = nil }
            throw ProtocolError(code: .internal, message: "adb start-server failed")
        }
        return tool
    }

    func devices() async throws(ProtocolError) -> [AdbDevice] {
        AdbParsing.devices(try await tool().run(["devices", "-l"], serial: nil, timeout: .seconds(15)).stdout)
    }

    static func attempt<T: Sendable>(_ f: @Sendable () async throws(ProtocolError) -> T) async -> Result<T, ProtocolError> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    /// `s`: an adb serial, `avd:<name>` (booted when off) or a simulator UDID (a simulator not booted yet is booted first); nil: the only Android device
    /// in state `device` or simulator `booted`. adb or simctl failing hides only its own devices; both failing: adb's error.
    /// `frame`: the panel's device frame (`DeviceFrame`); reading the type never fails the call, it falls back to `bare`.
    func resolveSerial(_ s: String?) async throws(ProtocolError) -> (serial: String, platform: String, frame: DeviceFrame.Kind) {
        if let s, s.hasPrefix("avd:") {
            let name = String(s.dropFirst(4))
            return (try await bootAvd(name), "android", avdFrame(name))
        }
        var adbError: ProtocolError?, simError: ProtocolError?, all: [AdbDevice] = [], sims: [SimDevice]?
        async let adbR = Self.attempt { () async throws(ProtocolError) in try await self.devices() }   // concurrent: a cold CoreSimulator must not slow Android
        async let simR = Self.attempt { () async throws(ProtocolError) in try await self.simulators() }
        switch await adbR { case .success(let v): all = v; case .failure(let e): adbError = e }
        switch await simR { case .success(let v): sims = v; case .failure(let e): simError = e }
        if let adbError, sims == nil { throw adbError }
        if let s, !s.isEmpty {
            if all.contains(where: { $0.serial == s }) { return (s, "android", await androidFrame(serial: s)) }
            if let sim = sims?.first(where: { $0.udid == s }) {
                try await boot(sim); return (s, "ios", DeviceFrame.ios(deviceTypeIdentifier: sim.deviceType))
            }
            if let simError, UUID(uuidString: s) != nil { throw simError }   // a UDID, but simctl is gone
            if let adbError { throw adbError }   // likely an Android serial, but adb is gone
            let known = all.map(\.serial) + (sims ?? []).map(\.udid)
            throw ProtocolError(code: .invalidArgs, message: "Unknown device '\(s)' (\(known.isEmpty ? "none connected" : known.joined(separator: ", ")))")
        }
        // (serial, platform, how the error lists it)
        let online = all.filter { $0.state == "device" }.map { ($0.serial, "android", $0.serial, nil as SimDevice?) }
            + (sims ?? []).filter { $0.state == "booted" }.map { ($0.udid, "ios", "\($0.udid) (\($0.name))", Optional($0)) }
        switch online.count {
        case 1:
            let (serial, platform, _, sim) = online[0]
            let frame = if let sim { DeviceFrame.ios(deviceTypeIdentifier: sim.deviceType) } else { await androidFrame(serial: serial) }
            return (serial, platform, frame)
        case 0:
            let others = all.map { "\($0.serial) \($0.state)" } + (sims ?? []).map { "\($0.udid) (\($0.name)) \($0.state)" }
            throw ProtocolError(code: .invalidArgs, message: "No device online" + (others.isEmpty ? "" : " (" + others.joined(separator: ", ") + ")"))
        default: throw ProtocolError(code: .invalidArgs, message: "Several devices online (\(online.map(\.2).joined(separator: ", "))); pass --serial")
        }
    }

    func run(_ command: String, panel: Panel?, args: [String: JSONValue], cwd: String?) async throws(ProtocolError) -> JSONValue {
        guard let panel, case .string(let serial)? = panel.state["serial"] else {
            throw ProtocolError(code: .invalidArgs, message: "'\(command)' needs a device panel")
        }
        if panel.state["platform"] != .string("ios") {
            kickHelper(panel: panel.id, serial: serial)
            await helpers[serial]?.recover()   // H7/A1: a fallback is retried along DeviceHelper.retrySchedule (2, 5, 15, then 30 s)
        }
        func act(_ c: String, _ a: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
            if panel.state["platform"] == .string("ios") { return try await runIOS(c, panel: panel, udid: serial, args: a, cwd: cwd) }
            return try await runAndroid(c, panel: panel, serial: serial, args: a, cwd: cwd)
        }
        func dump() async throws(ProtocolError) -> [UINode] {
            _ = try await act("device.ui", [:])   // the device.ui path: refs updated
            return refs[panel.id] ?? []
        }
        func screen(all: Bool, timing: Bool = false, ocrMode: OCRMode = .auto) async throws(ProtocolError) -> [String: JSONValue] {
            let ui = try await act("device.ui", ["all": .bool(all), "timing": .bool(timing)])
            let start = ContinuousClock.now
            var nodes = refs[panel.id] ?? []
            // O2: the OCR runs only when the trigger fires (Android and, A3, iOS); the screenshot, the OCR and the merge stay in memory
            var read: OCRRead?
            if let trigger = ocrMode.trigger(nodes) {
                read = await ocrRead(panel: panel, serial: serial, tree: nodes, trigger: trigger, region: ocrMode.region)
                if let found = read?.nodes, !found.isEmpty, !closed.contains(panel.id) { nodes += found; refs[panel.id] = nodes }
            }
            var screen = ScreenModel.build(nodes)
            screen.changed = ScreenModel.changes(from: lastScreen[panel.id], to: screen)
            if !closed.contains(panel.id) { lastScreen[panel.id] = screen }
            var o = ScreenModel.json(screen)
            let sig = ScreenSignature.compute(screen)
            o["sig"] = .string(sig)
            if case .string(let text)? = o["text"] { o["text"] = .string(text + "\nsig=\(sig)") }
            if let read, read.nodes == nil {
                o["ocr"] = .string("unavailable")
                if case .string(let text)? = o["text"] { o["text"] = .string(text + "\nocr: unavailable") }
            }
            guard case .object(let u) = ui else { return o }
            if all { o["tree"] = u["tree"] }
            if timing, case .object(var t)? = u["timingMs"] {
                t["group"] = Self.ms(ContinuousClock.now - start - (read?.took ?? .zero))
                t["sig"] = .string(sig)
                if let read {
                    t["ocrMs"] = Self.ms(read.took); t["ocrLevel"] = .string(OCRLevel.accurate.rawValue); t["trigger"] = .string(read.trigger)
                }
                o["timingMs"] = .object(t)
            }
            return o
        }
        if command == "device.screen" {
            return .object(try await screen(all: args["all"] == .bool(true), timing: Self.timing(args), ocrMode: try Self.ocrMode(args)))
        }
        /// `--then ui|screen`: the tree (`ui`) or the groups (`screen`) added to `o`.
        func shown(_ then: (screen: Bool, settleMs: Int?), _ o: inout [String: JSONValue]) async throws(ProtocolError) {
            if then.screen { o["screen"] = .object(try await screen(all: false)) } else { o["ui"] = try await act("device.ui", [:]) }
        }
        /// `--stable` (H4): with the helper ready, the text by dumps and then the stability by its `subscribe` events (none
        /// for `quietMs`); without it, or when it drops midway, two equal dumps in a row (`poll`).
        func wait(_ w: Wait) async throws(ProtocolError) -> (ok: Bool, waitedMs: Int, last: [UINode]) {
            guard w.stable, panel.state["platform"] != .string("ios"), let h = helpers[serial], await h.state == .ready else {
                return try await poll(w, dump: dump)
            }
            let start = ContinuousClock.now
            func waited() -> Int { Int((ContinuousClock.now - start) / .milliseconds(1)) }
            func left() -> Int { max(1, w.timeoutMs - waited()) }
            var last: [UINode] = []
            if w.text != nil {
                let r = try await poll(Wait(text: w.text, gone: w.gone, stable: false, timeoutMs: w.timeoutMs), dump: dump)
                guard r.ok else { return r }
                last = r.last
            }
            switch await h.quiet(w.quietMs, timeoutMs: left()) {
            case true?: return (true, waited(), last)
            case false?: return (false, waited(), try await dump())
            case nil:
                let r = try await poll(Wait(text: w.text, gone: w.gone, stable: true, timeoutMs: left()), dump: dump)
                return (r.ok, waited(), r.last)
            }
        }
        if command == "device.wait" {
            let w = try Self.waitSpec(args)
            let then = try Self.then(args)   // checked before the first dump
            let r = try await wait(w)
            guard r.ok else {
                let limit = w.timeoutMs % 1000 == 0 ? "\(w.timeoutMs / 1000) s" : "\(w.timeoutMs) ms"
                throw ProtocolError(code: .timeout, message: "device.wait: \(w.what) not reached in \(limit)\(w.clamped ? " (" + Self.clampNote + ")" : ""). Last screen:\n"
                                    + ScreenModel.text(ScreenModel.build(r.last)))
            }
            var o: [String: JSONValue] = ["ok": .bool(true), "waitedMs": .number(Double(r.waitedMs))]
            if w.clamped { o["clamped"] = .bool(true); o["warning"] = .string(Self.clampNote) }
            if let then { try await shown(then, &o) }   // ponytail: one more dump, the wait's last one is not reused
            return .object(o)
        }
        /// O4 (O2 rule 4): `find`/`tap --text` with no tree match read the screenshot once (`--region`: that rectangle);
        /// the OCR items join the refs. nil: `--no-ocr`, the tree already has OCR items, or nothing read.
        func ocrFallback(_ nodes: [UINode], _ mode: OCRMode) async -> (nodes: [UINode], read: OCRRead)? {
            guard !mode.off, !nodes.contains(where: \.ocr) else { return nil }
            let read = await ocrRead(panel: panel, serial: serial, tree: nodes, trigger: OCRTrigger.find.rawValue, region: mode.region)
            guard let found = read.nodes, !found.isEmpty else { return nil }
            if !closed.contains(panel.id) { refs[panel.id] = nodes + found }
            return (nodes + found, read)
        }
        let ocrMode = command == "device.find" || command == "device.tap" ? try Self.ocrMode(args) : .auto
        if command == "device.find" {
            let q = try Self.findSpec(args)
            /// The tree match, else (no --role: OCR items have none) the OCR fallback's.
            func found(_ nodes: [UINode]) async throws(ProtocolError) -> [String: JSONValue] {
                do { return try Self.find(nodes, text: q.text, role: q.role) } catch where error.code == .notFound {
                    guard q.role == nil, let f = await ocrFallback(nodes, ocrMode) else { throw error }
                    var o = try Self.find(f.nodes, text: q.text, role: nil)
                    if Self.timing(args) { o["timingMs"] = Self.ocrTiming(f.read) }
                    return o
                }
            }
            if let scroll = q.scroll {
                var o = try await findScrolling(q.text, role: q.role, scroll, dump: dump, swipe: { a throws(ProtocolError) in _ = try await act("device.swipe", a) })
                if q.screen { o["screen"] = .object(try await screen(all: false)) }   // ponytail: one more dump for the groups
                return .object(o)
            }
            guard q.screen else { return .object(try await found(try await dump())) }
            let shown = try await screen(all: false)   // one dump serves both (refs updated)
            var o = try await found(refs[panel.id] ?? [])
            o["screen"] = .object(shown)
            return .object(o)
        }
        let then = try Self.then(args)   // checked before the action: a bad --then must not tap
        let quiet = try Self.quietMs(args)
        var args = args
        var viaOCR: OCRRead?
        if command == "device.tap", let pick = try Self.tapPick(args) {
            _ = try await act("device.ui", [:])   // always a fresh dump: cached refs may be stale
            let nodes = refs[panel.id] ?? []
            do { args["ref"] = .string(try UITree.target(nodes, text: pick.text, id: pick.id, nth: pick.nth).ref) } catch where error.code == .notFound {
                guard pick.id == nil, let f = await ocrFallback(nodes, ocrMode) else { throw error }
                args["ref"] = .string(try UITree.target(f.nodes, text: pick.text, id: nil, nth: pick.nth).ref)   // an OCR ref: its box centre
                viaOCR = f.read
            }
        }
        var r = try await act(command, args)
        if let read = viaOCR, case .object(var o) = r {
            o.merge(Self.ocrNote, uniquingKeysWith: { _, b in b })
            if Self.timing(args) { o["timingMs"] = Self.ocrTiming(read) }
            r = .object(o)
        }
        guard let then, Self.thenCommands.contains(command), case .object(var o) = r else { return r }
        if let ms = then.settleMs {
            // ponytail: fixed settle, may catch an animation midway; --settle stable waits for it
            await Self.nap(.milliseconds(ms))
        } else {
            // the action already ran: a screen that never settles returns its last tree anyway, with settled false
            o["settled"] = .bool(try await wait(Wait(text: nil, gone: false, stable: true, timeoutMs: Self.stableSettleMs, quietMs: quiet)).ok)
        }
        try await shown(then, &o)
        return .object(o)
    }

    /// What `device.wait` waits for: `text` to show (or go, `gone`), and/or two equal dumps in a row (`stable`).
    struct Wait {
        let text: String?; let gone: Bool; let stable: Bool; let timeoutMs: Int
        /// `--timeout` asked for more than 60 s and got 60 s (`waitTimeoutMs`).
        var clamped = false
        /// With the helper: `stable` holds once no screen event came for this long.
        var quietMs = DeviceService.stableQuietMs
        var what: String { [text.map { "text '\($0)' " + (gone ? "gone" : "shown") }, stable ? "stable screen" : nil].compactMap { $0 }.joined(separator: " + ") }
        /// `text` (any case, in a node's text or desc, containing) shows or, with `gone`, is absent.
        func textMet(_ nodes: [UINode]) -> Bool {
            guard let t = text?.lowercased() else { return true }
            return nodes.contains { $0.text.lowercased().contains(t) || $0.desc.lowercased().contains(t) } != gone
        }
    }

    /// `--settle stable` after an action: at most this long for two equal dumps.
    static let stableSettleMs = 5000
    /// `--quiet` default: ms without a helper event for a screen to count as stable.
    static let stableQuietMs = 300
    /// `--quiet <ms>` (50-5000) of `wait --stable` and `--settle stable`; the default when absent.
    static func quietMs(_ a: [String: JSONValue]) throws(ProtocolError) -> Int { try int(a, "quiet", 50...5000) ?? stableQuietMs }
    /// Pause between two dumps of a wait (a dump itself takes 2-3 s on Android).
    static let pollGapMs = 200

    /// `device.find --scroll`: `up` swipes the other way (to go back up a list); `max` swipes at most.
    struct Scroll: Equatable { let up: Bool; let max: Int }
    /// `device.find --scroll` without --max.
    static let defaultMaxScrolls = 8
    /// Pause after each `find --scroll` swipe before the next dump (the `--then` default; the dump itself takes 2-3 s).
    static let scrollSettleMs = 400

    /// `device.find` args: the text (required), --role tab|button|field, --then screen (nothing else),
    /// --scroll with --dir down|up (default down) and --max 1-30 (default 8); --dir/--max without --scroll: invalidArgs.
    static func findSpec(_ a: [String: JSONValue]) throws(ProtocolError) -> (text: String, role: String?, screen: Bool, scroll: Scroll?) {
        guard case .string(let text)? = a["text"], !text.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "device.find needs a text") }
        var role: String?
        switch a["role"] {
        case nil, .null?: role = nil
        case .string(let r)? where ["tab", "button", "field"].contains(r): role = r
        default: throw ProtocolError(code: .invalidArgs, message: "--role takes tab, button or field")
        }
        let screen: Bool
        switch a["then"] {
        case nil, .null?: screen = false
        case .string("screen")?: screen = true
        default: throw ProtocolError(code: .invalidArgs, message: "device.find --then only takes 'screen'")
        }
        let up: Bool
        switch a["dir"] {
        case nil, .null?, .string("down")?: up = false
        case .string("up")?: up = true
        default: throw ProtocolError(code: .invalidArgs, message: "--dir takes down or up")
        }
        let max = try int(a, "max", 1...30)
        guard a["scroll"] == .bool(true) || a["scroll"] == .string("true") else {
            if a["dir"] != nil && a["dir"] != .null || max != nil { throw ProtocolError(code: .invalidArgs, message: "--dir and --max need --scroll") }
            return (text, role, screen, nil)
        }
        return (text, role, screen, Scroll(up: up, max: max ?? defaultMaxScrolls))
    }

    /// `device.find --scroll`: dump, look (`find`); not there: swipe from 75% to 35% of the height (`up`: back) in the
    /// middle of the width, wait `scrollSettleMs`, dump again. Stops when found, when the tree stays the same after a
    /// swipe (end of the list: `endReached`) or after `max` swipes. The answer and the notFound message carry
    /// `scrolls` and `endReached`. The size is the extent of the dumped nodes (Android pixels, iOS points).
    func findScrolling(_ text: String, role: String?, _ s: Scroll, dump: () async throws(ProtocolError) -> [UINode],
                       swipe: ([String: JSONValue]) async throws(ProtocolError) -> Void) async throws(ProtocolError) -> [String: JSONValue] {
        var nodes = try await dump(), scrolls = 0
        while true {
            let miss: String
            do {
                var o = try Self.find(nodes, text: text, role: role)
                o["scrolls"] = .number(Double(scrolls)); o["endReached"] = .bool(false)
                return o
            } catch where error.code == .notFound { miss = error.message }
            func notFound(_ end: Bool) -> ProtocolError {
                ProtocolError(code: .notFound, message: miss + " (scrolls: \(scrolls), endReached: \(end))")
            }
            guard scrolls < s.max, !Task.isCancelled else { throw notFound(false) }
            // ponytail: the extent of the kept nodes (the bare root is dropped); `wm size` if a short tree swipes too little
            let box = nodes.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            let x = box.isNull ? 0 : Double(Int(box.midX)), h = box.isNull ? 0 : box.maxY
            let low = Double(Int(h * 0.75)), high = Double(Int(h * 0.35))
            try await swipe(["x1": .number(x), "y1": .number(s.up ? high : low), "x2": .number(x), "y2": .number(s.up ? low : high)])
            scrolls += 1
            await Self.nap(.milliseconds(Self.scrollSettleMs))
            let next = try await dump()
            if next == nodes { throw notFound(true) }   // the swipe moved nothing: end of the list
            nodes = next
        }
    }

    /// `device.find`: the `tap --text` match (UITree.target) on one dump, its role and label from the ScreenModel
    /// groups. Several matches: the first in tree order. None (or none with `role`): notFound with similar labels.
    static func find(_ nodes: [UINode], text: String, role: String?) throws(ProtocolError) -> [String: JSONValue] {
        let s = ScreenModel.build(nodes, cap: .max)
        let groups = [s.back].compactMap { $0 } + s.tabs + s.actions + s.fields + s.content + s.floating
        let items = Dictionary(groups.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let n = try UITree.target(nodes, text: text, id: nil, nth: 1, keep: { role == nil || (!$0.ocr && items[$0.ref]?.role == role) })
        let it = items[n.ref]
        let o: [String: JSONValue] = ["found": .bool(true), "ref": .string(n.ref), "label": .string(it?.label ?? (n.text.isEmpty ? n.desc : n.text)),
                "role": .string(it?.role ?? "text"), "clickable": .bool(n.clickable),
                "center": .object(["x": .number(Double(n.center.x)), "y": .number(Double(n.center.y))])]
        return n.ocr ? o.merging(ocrNote, uniquingKeysWith: { _, b in b }) : o
    }

    /// O4: what a `find`/`tap` answer carries when the element came from the OCR (text with a box, no role, no click info).
    static let ocrNote: [String: JSONValue] = ["via": .string("ocr"),
        "warning": .string("found by OCR: no click confirmation, check with --then screen")]
    /// `--timing` of the OCR fallback (O5): `ocrMs`, `ocrLevel`, `trigger` (find).
    static func ocrTiming(_ read: OCRRead) -> JSONValue {
        .object(["ocrMs": ms(read.took), "ocrLevel": .string(OCRLevel.accurate.rawValue), "trigger": .string(read.trigger)])
    }

    /// `device.wait` args: --text and/or --stable (--gone needs --text), --timeout (`waitTimeoutMs`, default 10 s).
    static func waitSpec(_ a: [String: JSONValue]) throws(ProtocolError) -> Wait {
        let text: String? = if case .string(let s)? = a["text"], !s.isEmpty { s } else { nil }
        func flag(_ k: String) -> Bool { a[k] == .bool(true) || a[k] == .string("true") }
        let gone = flag("gone"), stable = flag("stable")
        guard text != nil || stable else { throw ProtocolError(code: .invalidArgs, message: "device.wait needs --text or --stable") }
        guard !gone || text != nil else { throw ProtocolError(code: .invalidArgs, message: "--gone needs --text") }
        let t = try waitTimeoutMs(a["timeout"])
        var w = Wait(text: text, gone: gone, stable: stable, timeoutMs: t?.ms ?? 10_000, quietMs: try quietMs(a))
        w.clamped = t?.clamped ?? false
        return w
    }

    /// `device.wait --timeout`: `30` or `30s` (seconds) or `500ms`, in ms; above 60 s (`120000ms`, `120000`) it is 60 s
    /// with `clamped` (P3: an agent asked for 120000 and got an error). nil when absent; not a positive integer: invalidArgs.
    static func waitTimeoutMs(_ v: JSONValue?) throws(ProtocolError) -> (ms: Int, clamped: Bool)? {
        let ms: Int?
        switch v {
        case nil, .null?: return nil
        case .number(let n)?: ms = Int(exactly: n).map { min($0, 61) * 1000 }
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasSuffix("ms") { ms = Int(String(t.dropLast(2))) } else {
                ms = Int(t.hasSuffix("s") ? String(t.dropLast()) : t).map { min($0, 61) * 1000 }
            }
        default: ms = nil
        }
        guard let ms, ms >= 1 else {
            let raw = switch v { case .string(let s)?: "'\(s)'"; case .number(let n)?: "\(n)"; default: "a non-number" }
            throw ProtocolError(code: .invalidArgs, message: "--timeout takes 30, 30s or 500ms (at most 60 s), got \(raw)")
        }
        return ms > 60_000 ? (60_000, true) : (ms, false)
    }
    static let clampNote = "--timeout above 60 s: waited at most 60 s"

    /// Dumps until `w` holds or its timeout passes (checked after each dump: one dump may overrun it).
    func poll(_ w: Wait, dump: () async throws(ProtocolError) -> [UINode]) async throws(ProtocolError) -> (ok: Bool, waitedMs: Int, last: [UINode]) {
        let start = ContinuousClock.now
        var prev: [UINode]?
        while true {
            let nodes = try await dump()
            let waited = Int((ContinuousClock.now - start) / .milliseconds(1))
            if w.textMet(nodes), !w.stable || prev == nodes { return (true, waited, nodes) }
            if waited >= w.timeoutMs || Task.isCancelled { return (false, waited, nodes) }
            prev = nodes
            await Self.nap(.milliseconds(Self.pollGapMs))
        }
    }

    /// `device.tap --text/--id` (with `--nth`): what to look for; nil when tapping by x y or --ref. Exactly one of
    /// x y, --ref, --text/--id: otherwise invalidArgs.
    static func tapPick(_ a: [String: JSONValue]) throws(ProtocolError) -> (text: String?, id: String?, nth: Int?)? {
        func str(_ k: String) -> String? { if case .string(let s)? = a[k], !s.isEmpty { s } else { nil } }
        func has(_ k: String) -> Bool { a[k] != nil && a[k] != .null }
        let text = str("text"), id = str("id")
        let ways = [has("x") || has("y"), has("ref"), text != nil || id != nil].filter { $0 }.count
        guard ways == 1 else {
            throw ProtocolError(code: .invalidArgs, message: "device.tap needs exactly one of: x y, --ref, --text/--id")
        }
        guard text != nil || id != nil else { return nil }
        return (text, id, try int(a, "nth", 1...10_000))
    }

    /// A duration in whole ms, for `--timing`'s `timingMs`.
    static func ms(_ d: Duration) -> JSONValue { .number((d / .milliseconds(1)).rounded()) }
    /// `--timing` set (a flag arrives as true or "true").
    static func timing(_ a: [String: JSONValue]) -> Bool { a["timing"] == .bool(true) || a["timing"] == .string("true") }

    /// A plain timed wait (cancellation ends it early), for the waits that are about time, not an event.
    static func nap(_ d: Duration) async { try? await Task.sleep(for: d) }

    /// The actions that take `--then ui|screen` (and `--settle`).
    static let thenCommands: Set<String> = ["device.tap", "device.swipe", "device.text", "device.key", "device.launch"]

    /// `--then ui|screen` with `--settle <ms>` (0-3000, default 400; `settleMs`) or `--settle stable` (nil `settleMs`);
    /// no `--then`: nil. Any other value: invalidArgs.
    static func then(_ a: [String: JSONValue]) throws(ProtocolError) -> (screen: Bool, settleMs: Int?)? {
        let screen: Bool
        switch a["then"] {
        case nil, .null?: return nil
        case .string("ui")?: screen = false
        case .string("screen")?: screen = true
        default: throw ProtocolError(code: .invalidArgs, message: "--then only takes 'ui' or 'screen'")
        }
        if a["settle"] == .string("stable") { return (screen, nil) }
        return (screen, try int(a, "settle", 0...3000) ?? 400)
    }

    /// Checked after every await that precedes a write: a panel closed meanwhile gets nothing written for it.
    func alive(_ panel: Panel) throws(ProtocolError) {
        if closed.contains(panel.id) { throw ProtocolError(code: .notFound, message: "Panel '\(panel.name)' was closed meanwhile") }
    }

    /// Integer in `range` (default pixels 0...100000), from a number or numeric string; nil when absent.
    static func int(_ a: [String: JSONValue], _ k: String, _ range: ClosedRange<Int> = 0...100_000) throws(ProtocolError) -> Int? {
        let v: Int?
        switch a[k] {
        case nil, .null?: return nil
        case .number(let n)?: v = Int(exactly: n)
        case .string(let s)?: v = Int(s)
        default: v = nil
        }
        guard let v, range.contains(v) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(k)' must be an integer between \(range.lowerBound) and \(range.upperBound)")
        }
        return v
    }

    // MARK: video

    /// A `ui.device` viewer of `panel`: opens `conn` and joins the panel's session, starting one if there is none.
    func attach(panel: Panel, conn: StreamConn, ok: Response) {
        idle.removeValue(forKey: panel.id)?.cancel()
        let s: any ViewerSession
        let serial = { if case .string(let v)? = panel.state["serial"] { v } else { "" } }()
        if let cur = sessions[panel.id], !cur.isEnded {
            s = cur
        } else if panel.state["platform"] == .string("ios") {
            let sim = SimSession(panel: panel.id, udid: serial, onEnd: { s in Task { await self.ended(s) } })
            s = sim
            sessions[panel.id] = sim
            let tools = self.sim, runDir = runDir
            Task { await sim.start(sim: tools, runDir: runDir) }
        } else {
            let dev = DeviceSession(panel: panel.id, serial: serial, onEnd: { s in Task { await self.ended(s) } })
            s = dev
            sessions[panel.id] = dev
            let jar = scrcpyServer, runDir = runDir
            Task {
                do throws(ProtocolError) { await dev.start(adb: try await self.tool(), jar: jar, runDir: runDir) }
                catch { dev.end("error", error.message) }
            }
        }
        conn.open(ok, onFrame: { [unowned conn, weak s] f in if case .in(let d) = f { s?.input(d, from: conn) } },
                  onClose: { [weak s] in Task { if let s { await self.left(s, conn) } } })
        if !s.join(conn) {   // ended between the check and the join (another thread): tell the viewer, it reconnects
            conn.send(.deviceStatus(state: "ended", message: nil)); conn.closeAfterFlush()
        }
    }

    /// The last viewer gone: the session ends after `grace` unless one comes back.
    private func left(_ s: any ViewerSession, _ c: StreamConn) {
        guard s.leave(c) == 0, sessions[s.panel] === s else { return }
        idle[s.panel]?.cancel()
        let grace = grace
        idle[s.panel] = Task {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self.idleOver(s)
        }
    }

    private func idleOver(_ s: any ViewerSession) {
        guard s.viewerCount == 0, sessions[s.panel] === s else { return }
        s.end("ended", "No viewers")
    }

    private func ended(_ s: any ViewerSession) {
        guard sessions[s.panel] === s else { return }
        sessions[s.panel] = nil
        idle.removeValue(forKey: s.panel)?.cancel()
    }

    /// The panel is gone: its session, screenshots and refs go too.
    func panelClosed(_ id: UUID) async {
        closed.insert(id)
        refs[id] = nil
        lastScreen[id] = nil
        simPoints[id] = nil
        idle.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)?.end("ended", "Panel closed")
        await helperPanelClosed(id)
        let prefix = id.uuidString + "-"
        for f in (try? FileManager.default.contentsOfDirectory(at: screens, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: watchers

    /// The device panels now open (any others in `panels` are ignored). Polls `adb devices -l` while there is one;
    /// watchers of serials no panel holds any more are stopped at once.
    func watch(panels: [Panel]) async {
        watched = [:]
        let hadIOS = !watchedIOS.isEmpty
        watchedIOS = [:]
        for p in panels where p.pluginId == "device" {
            guard case .string(let s)? = p.state["serial"] else { continue }
            if p.state["platform"] == .string("ios") { watchedIOS[p.id] = s } else { watched[p.id] = s }
        }
        if !hadIOS && !watchedIOS.isEmpty { iosSince = Date() }
        let udids = Set(watchedIOS.values)
        booted = booted.filter { udids.contains($0.key) }
        let wanted = Set(watched.values)
        for s in crash.keys where !wanted.contains(s) { endCrash(s) }
        online = online.filter { wanted.contains($0.key) }
        if wanted.isEmpty && udids.isEmpty {
            poller?.cancel(); poller = nil
        } else if poller == nil {
            let interval = pollInterval
            poller = Task { while !Task.isCancelled { await self.poll(); try? await Task.sleep(for: interval) } }
        }
    }

    private func poll() async { await pollAndroid(); await pollIOS() }

    /// One `adb devices -l`: a serial's first sighting is its baseline; later flips to/from `device` are events.
    private func pollAndroid() async {
        guard !watched.isEmpty, let all = try? await devices() else { return }   // adb missing/failing: try next tick
        // no await until every state change is applied: a `watch` in between must not see (or leave) a half-done poll
        var flips: [(serial: String, online: Bool, panels: [UUID])] = []
        for s in Set(watched.values) {
            let now = all.contains { $0.serial == s && $0.state == "device" }
            let was = online[s]; online[s] = now
            if !now { endCrash(s) } else if crash[s] == nil { crash[s] = CrashWatch(); Task { await self.startCrash(s) } }   // its `date` must not hold up the poll
            if let was, was != now { flips.append((s, now, watched.filter { $0.value == s }.map(\.key))) }
        }
        for f in flips {
            for id in f.panels { await emit(id, f.online ? "device.connected" : "device.disconnected", .object(["serial": .string(f.serial)])) }
        }
    }

    private func toPanels(of serial: String, _ name: String, _ payload: [String: JSONValue]) async {
        for (id, s) in watched.merging(watchedIOS, uniquingKeysWith: { a, _ in a }) where s == serial { await emit(id, name, .object(payload)) }
    }

    /// One `simctl list devices -j` (booted/shutdown flips, first sighting is the baseline) and one scan of the crash
    /// reports dir. Each applies its state with no await between reading and writing, then emits.
    private func pollIOS() async {
        guard !watchedIOS.isEmpty else { return }
        if let sims = try? await simulators() {
            var flips: [(String, Bool)] = []
            for u in Set(watchedIOS.values) {
                let now = sims.contains { $0.udid == u && $0.state == "booted" }
                let was = booted[u]; booted[u] = now
                if let was, was != now { flips.append((u, now)) }
            }
            // a shut-down simulator's `axe stream-video` may never exit by itself: its sessions end here
            for (u, on) in flips where !on {
                for (id, s) in watchedIOS where s == u { sessions[id]?.end("ended", "Simulator shut down") }
            }
            for (u, on) in flips { await toPanels(of: u, on ? "device.connected" : "device.disconnected", ["serial": .string(u)]) }
        }
        let (dir, since, seen) = (crashReports, iosSince, Set(seenIPS))
        // a report modified in the last 2 s may be half-written: left for a later poll, neither read nor marked seen
        let found = (try? await UnixSocketClient.offPool { () -> [(String, Data)] in
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            return urls.compactMap { u in
                guard u.pathExtension == "ips", !seen.contains(u.lastPathComponent),
                      let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > since, m < Date().addingTimeInterval(-2),
                      let d = try? Data(contentsOf: u) else { return nil }
                return (u.lastPathComponent, d)
            }
        }) ?? []
        var out: [(String, CrashEvent, String)] = []
        for (name, data) in found where !seenIPS.contains(name) {
            seenIPS.append(name)
            if seenIPS.count > 1000 { seenIPS.removeFirst() }
            for u in Set(watchedIOS.values) { if let e = IPSCrash.parse(data, udid: u) { out.append((u, e, name)) } }
        }
        for (u, e, name) in out {
            await toPanels(of: u, "device.crash", ["serial": .string(u), "package": e.package.map { .string($0) } ?? .null, "text": .string(e.text),
                                                   "path": .string(dir.appendingPathComponent(name).path)])
        }
    }

    /// Starts `serial`'s crash watcher from the device's clock (`-T <epoch>`: only crashes from now on).
    /// ponytail: each (re)start takes a fresh epoch, so a crash in the restart gap is missed rather than replayed twice.
    private func startCrash(_ serial: String) async {
        guard let w = crash[serial], w.proc == nil, !w.starting, online[serial] == true,
              watched.values.contains(serial) else { return }
        crash[serial]?.starting = true
        let tool = try? await tool()
        let date = try? await tool?.run(["shell", "date", "+%s"], serial: serial, timeout: .seconds(15)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard crash[serial]?.id == w.id else { return }   // stopped meanwhile
        crash[serial]?.starting = false
        guard let tool, let epoch = date, !epoch.isEmpty, epoch.allSatisfy(\.isASCII), epoch.allSatisfy(\.isNumber) else {
            return retry(serial, w.id)
        }
        let (lines, cont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(4096))
        do {
            crash[serial]?.proc = try LongProcess(executable: tool.url,
                args: ["-s", serial, "logcat", "-b", "crash", "-v", "brief", "-T", "\(epoch).000"],
                env: ProcessInfo.processInfo.environment, runDir: runDir,
                onLine: { cont.yield($0) }, onExit: { _ in cont.finish() })
            crash[serial]?.startedAt = .now
        } catch { cont.finish(); return retry(serial, w.id) }
        let id = w.id
        Task {   // one consumer keeps the lines in order; the exit is handled once they are all fed
            for await line in lines { await self.crashLine(serial, id, line) }
            await self.crashExited(serial, id)
        }
    }

    private func crashLine(_ serial: String, _ id: UUID, _ line: String) async {
        guard crash[serial]?.id == id, let events = crash[serial]?.log.feed(line: line) else { return }
        crash[serial]?.lineGen += 1
        let gen = crash[serial]?.lineGen
        Task {   // a Java crash ends with the next unrelated line; when none comes, 300 ms of quiet ends it
            await Self.nap(.milliseconds(300))
            await self.crashQuiet(serial, id, gen)
        }
        await emitCrashes(serial, events)
    }

    private func crashQuiet(_ serial: String, _ id: UUID, _ gen: Int?) async {
        guard crash[serial]?.id == id, crash[serial]?.lineGen == gen, let events = crash[serial]?.log.flush() else { return }
        await emitCrashes(serial, events)
    }

    private func emitCrashes(_ serial: String, _ events: [CrashEvent]) async {
        for e in events {
            await toPanels(of: serial, "device.crash", ["serial": .string(serial), "package": e.package.map { .string($0) } ?? .null,
                                                        "text": .string(e.text)])
        }
    }

    /// The logcat ended by itself: flush, then restart after the backoff while the device stays online.
    private func crashExited(_ serial: String, _ id: UUID) async {
        guard crash[serial]?.id == id, let events = crash[serial]?.log.flush() else { return }
        crash[serial]?.proc?.terminate()   // the leader is gone; whatever it left in its group goes too
        crash[serial]?.proc = nil
        await emitCrashes(serial, events)
        retry(serial, id)
    }

    /// Backoff 2 s doubling to 30 s; back to 2 s once a watcher has lived 30 s.
    private func retry(_ serial: String, _ id: UUID) {
        guard var w = crash[serial], w.id == id else { return }
        if ContinuousClock.now - w.startedAt >= .seconds(30) { w.backoff = .seconds(2) }
        let delay = w.backoff
        w.backoff = min(w.backoff * 2, .seconds(30)); w.startedAt = .now
        crash[serial] = w
        Task { try? await Task.sleep(for: delay); await self.startCrash(serial) }   // startCrash re-checks it is still wanted
    }

    private func endCrash(_ serial: String) { crash.removeValue(forKey: serial)?.proc?.terminate() }

    /// Daemon stop: ends every session and watcher and waits (≤ 1.5 s) for their groups, so the delayed KILL is not lost
    /// with the process; and for the sessions' `forward --remove` (≤ its 5 s adb timeout).
    func stop() async {
        refs = [:]
        watched = [:]; online = [:]; watchedIOS = [:]; booted = [:]
        poller?.cancel(); poller = nil
        let live = Array(sessions.values); sessions = [:]
        idle.values.forEach { $0.cancel() }; idle = [:]
        for s in live { s.end("ended", "Collie is shutting down") }
        for s in live { await s.cleanup?.value }
        for h in helpers.values { await h.close() }   // their forwards
        helperPanels = [:]
        let pids = crash.values.compactMap { $0.proc?.pid } + live.compactMap(\.pid)
        for s in Array(crash.keys) { endCrash(s) }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while pids.contains(where: { kill(-$0, 0) == 0 }) && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
