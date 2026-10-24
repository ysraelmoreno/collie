import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

typealias StreamConn = UnixSocketServer.Connection

/// Per-terminal attach fan-out. Output and exit arrive on the PTY queue; joins run there too (`serialized`),
/// so replay + subscribe is atomic with respect to output: nothing lost or duplicated between them.
final class Fanout: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [ObjectIdentifier: StreamConn] = [:]
    private var exitCode: Int32?
    let process: PTYProcess
    private let input = DispatchQueue(label: "collie.stream.input")   // keeps keystrokes and resizes in order, off the actor
    /// Attention state changes, in the order they happened (yielded under `lock`), consumed by one hub task.
    enum Signal: Sendable { case attention(String), cleared }
    private var quiet: QuietDetector
    static let inputQuiet: Duration = .milliseconds(1500)
    let signals: AsyncStream<Signal>
    private let signalSink: AsyncStream<Signal>.Continuation
    /// The user's keys, told at once (ApprovalTracker.input): a hop through the hub would let a dialog drawn meanwhile
    /// be raised and then cleared by the late input.
    private let onInput: @Sendable () -> Void
    init(_ process: PTYProcess, preset: Preset, onInput: @escaping @Sendable () -> Void = {}) {
        self.process = process; self.onInput = onInput; quiet = QuietDetector(preset: preset)
        (signals, signalSink) = AsyncStream.makeStream(of: Signal.self, bufferingPolicy: .unbounded)
    }
    func finishSignals() { signalSink.finish() }

    func join(_ c: StreamConn, _ snap: (data: Data, truncated: Bool)) {   // PTY queue
        c.send(.replay(snap.data, truncated: snap.truncated))
        let code: Int32? = lock.withLock { subs[ObjectIdentifier(c)] = c; return exitCode }   // always registered: untrack must close a stream attached after exit
        if let code { c.send(.exited(code: code)) }
        if !c.isOpen { remove(ObjectIdentifier(c)) }   // closed before it was added
    }
    func out(_ d: Data) {                     // PTY queue
        // ponytail: ANSI.strip per chunk: an escape split across chunks, or a cursor-positioned TUI, can hide a prompt
        lock.withLock {
            // a TUI redraws its dialog after every keypress/resize: output right after input is scanned when the window
            // ends (QuietDetector), and the hub reports once per held badge
            attend(quiet.feed(ANSI.strip(String(decoding: d, as: UTF8.self))))
        }
        let cs = lock.withLock { Array(subs.values) }
        guard !cs.isEmpty else { return }
        let line = StreamFrame.out(d).line    // encoded once for every subscriber
        cs.forEach { $0.send(line) }
    }
    func exited(_ code: Int32) {
        let cs = lock.withLock { exitCode = code; return Array(subs.values) }
        cs.forEach { $0.send(.exited(code: code)) }
        signalSink.finish()
    }
    var count: Int { lock.withLock { subs.count } }
    func remove(_ k: ObjectIdentifier) { lock.withLock { _ = subs.removeValue(forKey: k) } }
    func closeAll() { lock.withLock { let v = subs.values; subs = [:]; return Array(v) }.forEach { $0.close() } }

    /// Keys reached the terminal (the user's, or an approval's): a prompt on screen is answered. `signal`: tell the hub
    /// (which tells AskCoordinator); an approval already told it.
    func noteInput(signal: Bool = true) {
        if signal { onInput() }
        lock.withLock {
            quiet.input()
            if signal { signalSink.yield(.cleared) }   // the hub ignores it unless the badge is attention
        }
        DispatchQueue.global().asyncAfter(deadline: QuietDetector.windowEnd) { [weak self] in
            guard let self, lock.withLock({ attend(quiet.feed("")); return quiet.overflowArmed }) else { return }
            DispatchQueue.global().asyncAfter(deadline: QuietDetector.overflowEnd) { [weak self] in
                guard let self else { return }
                lock.withLock { attend(quiet.overflowCheck()) }
            }
        }
    }
    private func attend(_ why: String?) { if why != nil { signalSink.yield(.attention(quiet.lastReason)) } }   // under lock

    /// Only focus reports (`ESC[I`, `ESC[O`: the terminal view gained or lost focus): not the user's answer to anything.
    static func isFocusReport(_ d: Data) -> Bool {
        guard !d.isEmpty, d.count % 3 == 0 else { return false }
        return stride(from: d.startIndex, to: d.endIndex, by: 3).allSatisfy {
            d[$0] == 0x1B && d[$0 + 1] == 0x5B && (d[$0 + 2] == 0x49 || d[$0 + 2] == 0x4F)
        }
    }

    /// Client frames. Input is the user's keyboard: written verbatim. Bounded by `c`'s input backpressure.
    func input(_ f: StreamFrame, from c: StreamConn) {
        let p = process
        switch f {
        case .in(let d):
            if !Self.isFocusReport(d) { noteInput() }
            c.inputQueued(d.count)
            input.async {
                defer { c.inputDone(d.count) }
                guard !c.isCut else { return }   // earlier input was lost and reported: drop the rest
                do { try p.write(d, origin: .user) } catch {   // the app's keyboard/paste: the user's own (R16 allowlist)
                    // exited: the exit path sends `.exited`; stalled: tell the client input was lost (it reattaches)
                    if p.isRunning { c.abort() }
                }
            }
        case .resize(let cols, let rows): input.async { p.resize(cols: cols, rows: rows) }
        default: break
        }
    }
}

/// UI streams: terminal attach (replay + live output, input, resize) and workspace events (lifecycle + badges).
actor StreamHub {
    static let workingWindow: Duration = .seconds(2)
    static let tickEvery: Duration = .milliseconds(250)

    private struct Entry { var fan: Fanout; var scrollback: ScrollbackBuffer; var since = ContinuousClock.now }
    private let asks: AskCoordinator
    private var terminals: [UUID: Entry] = [:]
    private var badges: [UUID: StatusBadge] = [:]
    private var listeners: [ObjectIdentifier: StreamConn] = [:]
    private var ticker: Task<Void, Never>?

    init(asks: AskCoordinator) { self.asks = asks }

    func start() {
        // ponytail: badges by polling (4/s); push from AskCoordinator/output if the latency or cost ever matters
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickEvery)
                guard let self else { return }
                await self.tick()
            }
        }
    }
    func stop() {
        ticker?.cancel(); ticker = nil
        for t in terminals.values { t.fan.finishSignals(); t.fan.closeAll() }
        listeners.values.forEach { $0.close() }; listeners = [:]
    }

    /// A spawned terminal (call after AskCoordinator.attach: chains, does not replace, its handlers). Emits `.spawned`.
    /// `onInput`: the terminal's ApprovalTracker, told of the user's keys synchronously.
    func track(_ rec: TerminalRecord, process: PTYProcess, scrollback: ScrollbackBuffer, onInput: @escaping @Sendable () -> Void = {}) {
        let id = rec.id
        let fan = Fanout(process, preset: rec.preset, onInput: onInput)
        Task { [weak self] in
            for await sig in fan.signals {
                switch sig {
                case .attention(let why): await self?.attention(id, why)
                case .cleared: await self?.inputReceived(id)
                }
            }
        }
        terminals[id] = Entry(fan: fan, scrollback: scrollback)
        // The launch awaits between spawn and here, so a child that prints a prompt at once (`printf '(y/n)'`, a
        // trust dialog) may already have been read: scan that output and hook in on the PTY queue, atomically with
        // the reads (no attach can join before this block), or the prompt is never seen.
        process.serialized {
            let prevOut = process.onOutput
            process.onOutput = { prevOut?($0); fan.out($0) }
            fan.out(Data(scrollback.snapshot().data.suffix(4096)))   // no subscribers yet: detection only
        }
        let prevExit = process.onExit
        process.onExit = { [weak self] code in
            prevExit?(code); fan.exited(code)
            Task { await self?.exited(id, fan, code) }
        }
        emit(.spawned(rec))
    }
    /// Killed or replaced: closes its attach streams, forgets its badge.
    func untrack(_ id: UUID) {
        terminals.removeValue(forKey: id).map { $0.fan.finishSignals(); $0.fan.closeAll() }
        badges[id] = nil
    }

    func attach(_ id: UUID, _ c: StreamConn, ok: Response) -> Bool {
        guard let t = terminals[id] else { return false }
        let fan = t.fan, sb = t.scrollback, k = ObjectIdentifier(c)
        c.open(ok, onFrame: { [unowned c] in fan.input($0, from: c) }, onClose: { fan.remove(k) })
        fan.process.serialized { fan.join(c, sb.snapshot()) }
        return true
    }
    func listen(_ c: StreamConn, ok: Response) {
        let k = ObjectIdentifier(c)
        listeners[k] = c
        c.open(ok, onFrame: { _ in }, onClose: { [weak self] in Task { await self?.unlisten(k) } })
    }
    private func unlisten(_ k: ObjectIdentifier) { listeners[k] = nil }
    var currentBadges: [UUID: StatusBadge] { badges }
    /// Live subscriptions (attach + events); diagnostics/tests.
    var streamCount: Int { listeners.count + terminals.values.reduce(0) { $0 + $1.fan.count } }

    func emit(_ e: WorkspaceEvent) {
        guard !listeners.isEmpty else { return }
        let line = StreamFrame.event(e).line
        listeners.values.forEach { $0.send(line) }
    }

    /// The terminal is waiting for the user: badge + event, held until input (or an ask) arrives.
    private func attention(_ id: UUID, _ why: String) async {
        guard let t = terminals[id], t.fan.process.isRunning, badges[id] != .attention else { return }
        guard !(await asks.isBusy(id)) else { return }   // an ask prompt echoing "(y/n)" is not the user's call
        guard terminals[id]?.fan === t.fan, badges[id] != .attention else { return }   // re-check after the await
        badges[id] = .attention
        emit(.attention(id, reason: why))
        emit(.status(id, .attention))
    }
    /// ApprovalTracker raised (or restored) an approval (the screen, or Claude's hook, which the hub's detector never
    /// sees): attention, even while an ask is in flight — the tracker strips an ask's echo, so its match is real.
    func approvalRaised(_ a: Approval) async {
        let id = a.terminalId
        guard let t = terminals[id], t.fan.process.isRunning, badges[id] != .attention else { return }
        guard await asks.pendingApproval(id)?.id == a.id else { return }   // answered meanwhile: no stale badge
        guard terminals[id]?.fan === t.fan, badges[id] != .attention else { return }   // re-check after the await
        badges[id] = .attention
        emit(.attention(id, reason: a.reason))
        emit(.status(id, .attention))
    }

    /// An approval answered `id`'s prompt from the chat: as if the user typed it.
    /// The tracker already counted this input (`take`): telling it again would drop the output it holds.
    func answered(_ id: UUID) {
        terminals[id]?.fan.noteInput(signal: false)
        guard badges[id] == .attention else { return }
        badges[id] = .idle
        emit(.status(id, .idle))
    }

    /// The tracker dropped `id`'s approval (answered, dismissed, a Stop hook): its badge goes; `tick` restores it if
    /// another approval is pending.
    func approvalCleared(_ id: UUID) {
        guard badges[id] == .attention else { return }
        badges[id] = .idle
        emit(.status(id, .idle))
    }

    private func inputReceived(_ id: UUID) {   // the tracker was told already (`onInput`)
        guard badges[id] == .attention else { return }
        badges[id] = .idle
        emit(.status(id, .idle))
    }

    private func exited(_ id: UUID, _ fan: Fanout, _ code: Int32) async {
        guard terminals[id]?.fan === fan else { return }   // killed/replaced: no exit event for the old launch
        emit(.exited(id, code))
        await tick()
    }

    /// stopped: not running; working: ask in flight or output (or launch) within `workingWindow`; idle otherwise.
    private func tick() async {
        for (id, t) in terminals {
            let p = t.fan.process
            let b: StatusBadge
            if p.isRunning {
                let approval = await asks.pendingApproval(id), busy = await asks.isBusy(id)
                if badges[id] == .attention, approval != nil || !busy { continue }   // held until input or a new ask; an approval until answered
                // a pending approval whose badge an in-flight ask held back (an echo?) counts once the ask is over
                if let approval, !busy, terminals[id]?.fan === t.fan {
                    badges[id] = .attention
                    emit(.attention(id, reason: approval.reason))
                    emit(.status(id, .attention))
                    continue
                }
            }
            if !p.isRunning { b = .stopped }
            else if ContinuousClock.now - (p.lastOutputAt ?? t.since) < Self.workingWindow { b = .working }
            else { b = await asks.isBusy(id) ? .working : .idle }
            guard terminals[id]?.fan === t.fan, b == .stopped || p.isRunning, badges[id] != b else { continue }   // re-check after the await
            badges[id] = b
            emit(.status(id, b))
        }
    }
}
