import Foundation
import CollieCore
import CollieDevice
import CollieProtocol

/// What `DeviceService` drives of a panel's screen: `DeviceSession` (Android, scrcpy) or `SimSession` (iOS Simulator).
protocol ViewerSession: AnyObject, Sendable {
    var panel: UUID { get }
    var isEnded: Bool { get }
    var viewerCount: Int { get }
    var pid: pid_t? { get }
    /// Work the end left running (Android's `forward --remove`); the daemon stop waits for it.
    var cleanup: Task<Void, Never>? { get }
    /// Adds an open viewer; false when the session already ended.
    func join(_ c: StreamConn) -> Bool
    /// Viewers left.
    func leave(_ c: StreamConn) -> Int
    func input(_ d: Data, from c: StreamConn)
    /// Idempotent, from any thread.
    func end(_ st: String, _ message: String?)
}

extension DeviceSession: ViewerSession {}

/// One iOS Simulator panel's live screen: `axe stream-video` (MJPEG on stdout, a `LongProcess`) split into JPEGs and fanned
/// out to the panel's `ui.device` viewers. `videoMeta` is the screen in points (from `describe-ui`), what input uses.
/// Viewers' `in` frames are `SimInput` JSON, each run as one `axe` invocation, in order.
/// Ends once (stream exit, panel closed, daemon stop, idle grace): status to the viewers, stream terminated. Never restarted.
final class SimSession: ViewerSession, @unchecked Sendable {   // state under `lock`; `reader` on the stdout thread only
    let panel: UUID
    let udid: String
    /// A viewer with more than this queued (unsent) skips frames until it is back under (each JPEG stands alone).
    static let dropAbove = 1 << 20
    /// Inputs waiting or running; more are dropped.
    static let maxPending = 32
    /// Longest text a run of typed characters is coalesced into.
    static let maxText = 1000

    private let lock = NSLock()
    private var viewers: [ObjectIdentifier: StreamConn] = [:]
    private var state = "connecting"
    private var meta: StreamFrame?
    private var last: Data?              // the last frame's line: a viewer joining mid-stream sees the screen at once
    private var ended = false
    private var proc: LongProcess?
    private var sim: Simulator?
    private var queue: [[String]] = []   // `axe` arguments not started yet; one runner drains them in order
    private var running = false
    private var reader = MJPEGReader()
    private let onEnd: @Sendable (SimSession) -> Void

    init(panel: UUID, udid: String, onEnd: @escaping @Sendable (SimSession) -> Void) {
        self.panel = panel; self.udid = udid; self.onEnd = onEnd
    }

    var isEnded: Bool { lock.withLock { ended } }
    var viewerCount: Int { lock.withLock { viewers.count } }
    var pid: pid_t? { lock.withLock { proc?.pid } }
    var cleanup: Task<Void, Never>? { nil }

    /// Sets state unless the session already ended (then the caller undoes what it just made).
    private func own(_ set: () -> Void) -> Bool { lock.withLock { guard !ended else { return false }; set(); return true } }

    // MARK: viewers

    func join(_ c: StreamConn) -> Bool {
        lock.withLock {
            guard !ended else { return false }
            if let meta { c.send(meta) }
            c.send(.deviceStatus(state: state, message: nil))
            if let last { c.send(last) }
            viewers[ObjectIdentifier(c)] = c
            return true
        }
    }

    func leave(_ c: StreamConn) -> Int { lock.withLock { viewers[ObjectIdentifier(c)] = nil; return viewers.count } }

    /// Queued behind the previous input; dropped when it is not a valid `SimInput`, before `start`, or past `maxPending`.
    /// Typed characters join a `type` still waiting (one `axe type` per keystroke would back up and drop text).
    func input(_ d: Data, from c: StreamConn) {
        guard let i = try? JSONDecoder().decode(SimInput.self, from: d), let args = Self.argv(i) else { return }
        lock.withLock {
            guard !ended, let sim else { return }
            if args[0] == "type", let last = queue.last, last[0] == "type", last[2].count + args[2].count <= Self.maxText {
                queue[queue.count - 1][2] += args[2]
                return
            }
            guard queue.count + (running ? 1 : 0) < Self.maxPending else { return }
            queue.append(args)
            guard !running else { return }
            running = true
            let udid = udid
            Task { [weak self] in
                while let a = self?.lock.withLock({ () -> [String]? in
                    if let self, !self.queue.isEmpty { return self.queue.removeFirst() }
                    self?.running = false; return nil
                }) {
                    if self?.isEnded == false { _ = try? await sim.axe(a, udid: udid, timeout: .seconds(10)) }
                }
            }
        }
    }

    /// The `axe` arguments for `i` (`--udid` is added by `Simulator.axe`); nil when out of range or not typeable.
    static func argv(_ i: SimInput) -> [String]? {
        func n(_ v: Double, _ r: ClosedRange<Double> = 0...100_000) -> String? { r.contains(v) ? String(format: "%g", v) : nil }
        switch i {
        case .tap(let x, let y):
            guard let x = n(x), let y = n(y) else { return nil }
            return ["tap", "-x", x, "-y", y]
        case .swipe(let x1, let y1, let x2, let y2, let s):
            guard let x1 = n(x1), let y1 = n(y1), let x2 = n(x2), let y2 = n(y2), let s = n(s, 0...10) else { return nil }
            return ["swipe", "--start-x", x1, "--start-y", y1, "--end-x", x2, "--end-y", y2, "--duration", s]
        case .text(let t):
            guard !t.isEmpty, (try? SimText.validate(t)) != nil else { return nil }
            return ["type", "--", t]   // `--`: a text starting with "-" is text, not an option
        case .key(let u): return ["key", "\(u)"]
        case .button(let b): return IOSKeys.button(named: b).map { ["button", $0] }
        }
    }

    // MARK: startup

    /// describe-ui (screen size; AXe sometimes fails once, so twice) → meta → `axe stream-video`. Failure ends with `error`.
    func start(sim: Simulator, runDir: URL) async {
        guard own({ self.sim = sim }) else { return }
        guard let axe = sim.axe else { return end("error", Simulator.missingAXe.message) }
        var screen: CGSize?, failure = "axe describe-ui returned no screen size"
        for _ in 0..<2 where screen == nil {
            do throws(ProtocolError) {
                screen = AXeTree.parse(try await sim.axe(["describe-ui"], udid: udid, timeout: .seconds(30), cap: 32 << 20).stdoutData).screen
            } catch { failure = error.message }
            if isEnded { return }
        }
        guard let screen, screen.width >= 1, screen.height >= 1 else { return end("error", failure) }
        let f = StreamFrame.videoMeta(width: UInt32(screen.width.rounded()), height: UInt32(screen.height.rounded()))
        guard own({ meta = f; for c in viewers.values { c.send(f) } }) else { return }
        do throws(ProtocolError) {
            let p = try LongProcess(executable: axe, args: ["stream-video", "--format", "mjpeg", "--fps", "15", "--quality", "70",
                                                            "--scale", "0.5", "--udid", udid],
                                    env: ProcessInfo.processInfo.environment, runDir: runDir,
                                    onData: { [weak self] d in self?.feed(d) },
                                    onExit: { [weak self] code in self?.streamExited(code) })
            guard own({ proc = p }) else { p.terminate(); return }
        } catch {
            end("error", error.message)
        }
    }

    /// Stdout thread.
    private func feed(_ d: Data) {
        for j in reader.feed(d) { deliver(StreamFrame.jpeg(j).line) }
    }

    /// The first frame makes the session `streaming`. A viewer over `dropAbove` misses this one.
    private func deliver(_ line: Data) {
        lock.withLock {
            guard !ended else { return }
            last = line
            if state != "streaming" {
                state = "streaming"
                for c in viewers.values { c.send(.deviceStatus(state: state, message: nil)) }
            }
            for c in viewers.values where c.queuedBytes <= Self.dropAbove { c.send(line) }
        }
    }

    private func streamExited(_ code: Int32) {
        let streaming = lock.withLock { state == "streaming" }
        end(streaming ? "ended" : "error", "axe stream-video exited (\(code))")
    }

    // MARK: end

    func end(_ st: String, _ message: String?) {
        let gone: LongProcess?? = lock.withLock {
            guard !ended else { return nil }
            ended = true; state = st
            let f = StreamFrame.deviceStatus(state: st, message: message)
            for c in viewers.values { c.send(f); c.closeAfterFlush() }
            viewers = [:]
            return .some(proc)
        }
        guard let gone else { return }
        gone?.terminate()   // queued inputs see `ended` and skip
        onEnd(self)
    }
}
