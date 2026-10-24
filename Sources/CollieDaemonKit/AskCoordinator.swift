import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

public struct AskResult: Sendable, Equatable {
    public enum Source: String, Sendable { case hook, idle }
    public var output: String
    public var source: Source
    public var truncated: Bool
    public init(output: String, source: Source, truncated: Bool) {
        self.output = output; self.source = source; self.truncated = truncated
    }
}

/// Tracks whether a terminal enabled bracketed paste (`ESC[?2004h` / `ESC[?2004l`); fed from the PTY queue.
final class PasteModeTracker: @unchecked Sendable {
    private static let on = Data("\u{1B}[?2004h".utf8), off = Data("\u{1B}[?2004l".utf8)
    private let lock = NSLock()
    private var carry = Data()      // tail of the previous read: sequences may split across reads
    private var _enabled = false
    var enabled: Bool { lock.withLock { _enabled } }

    func feed(_ d: Data) {
        lock.withLock {
            let buf = carry + d
            let a = buf.range(of: Self.on, options: .backwards)?.lowerBound
            let b = buf.range(of: Self.off, options: .backwards)?.lowerBound
            if let a, a > (b ?? Int.min) { _enabled = true } else if b != nil { _enabled = false }
            carry = Data(buf.suffix(Self.on.count - 1))
        }
    }
}

/// What happened to a terminal's pending approval: `raised` a new one (the chat says so), `updated` the same one
/// (redrawn at another width, or restored after keys it ignored), `cleared` (answered: input, an approval).
enum ApprovalEvent: Sendable, Equatable { case raised(Approval), updated(Approval), cleared(UUID) }

/// The approval prompt a terminal shows that nobody answered: the hub's `AttentionDetector` on the output, fed on the
/// PTY queue (no hop through the hub, so no lag), or Claude Code's `Notification` hook. Only input clears it (the user's
/// keys, a written prompt, an approval) or a new, different prompt replaces it, so the chat never types into a dialog
/// it lost track of. Output right after an input is scanned once `Fanout.inputQuiet` is over (`QuietDetector`); keys the
/// prompt ignored (nothing printed, or only an in-place redraw) put it back then.
/// An approval is written only while its captured text (`Approval.prompt`) is still a contiguous block of the last
/// `screenLines` non-empty lines (`take`).
final class ApprovalTracker: @unchecked Sendable {
    static let promptLines = 15, screenLines = 40
    private let lock = NSLock()
    private var quiet: QuietDetector
    private let terminalId: UUID, name: String
    private let scrollback: ScrollbackBuffer
    /// Called under the lock, so events keep their order.
    private let onEvent: @Sendable (ApprovalEvent) -> Void
    private var _pending: Approval?
    private var fromHook = false   // raised by the hook: the screen match that follows is the same dialog
    private var heldHook: String?  // a hook that came right after input: raised when the window ends
    private var restorable: Approval?   // cleared by input: back if the keys drew no reaction (window end)
    private var inputs = 0         // counts inputs: a re-raise only if none came since the answer
    /// `now`: tests drive the clock.
    init(terminalId: UUID, name: String, preset: Preset, scrollback: ScrollbackBuffer,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, onEvent: @escaping @Sendable (ApprovalEvent) -> Void) {
        self.terminalId = terminalId; self.name = name; self.scrollback = scrollback; self.onEvent = onEvent
        quiet = QuietDetector(preset: preset, now: now)
    }
    var pending: Approval? { lock.withLock { _pending } }
    /// Output since the last input is not scanned yet (its window is open, or over and not scanned): a prompt may be
    /// on screen that `pending` doesn't show yet.
    var inWindow: Bool { lock.withLock { quiet.unscanned } }

    func feed(_ d: Data) { scan(ANSI.strip(String(decoding: d, as: UTF8.self))) }

    private func scan(_ text: String) {
        lock.withLock {
            let why = quiet.feed(text)
            let prev = quiet.ended != nil ? restorable : nil
            if quiet.ended != nil { restorable = nil }
            if let why {
                heldHook = nil   // the screen saw the dialog itself
                let prompt = Self.capture(scrollback)
                // the hook's dialog now drawn (the card shows it: an event), or the same one drawn again (a resize:
                // same id, no chat line, no event — the card's text only wraps differently)
                if var a = _pending, fromHook || Self.sameDialog(a, why, prompt) {
                    a.prompt = prompt; _pending = a
                    if fromHook { fromHook = false; onEvent(.updated(a)) }
                    return
                }
                // the cleared prompt drawn again (an arrow key moved Select's cursor): the same request, no chat line
                if var prev, _pending == nil, Self.sameDialog(prev, why, prompt) { prev.prompt = prompt; restore(prev); return }
                onEvent(.raised(raise(AttentionDetector.kind(why), why, hook: false)))
                return
            }
            // ponytail: keys that printed no newline (nothing, an in-place redraw, a char typed at a line prompt) left
            // the prompt where it was; ceiling — a program that takes the key silently and works quietly for the window
            // is taken for one that ignored it (as R9), until the next input
            if let prev, _pending == nil, quiet.ended?.contains("\n") == false { restore(prev); return }
            guard let m = heldHook, !quiet.unscanned else { return }
            heldHook = nil
            if _pending == nil { onEvent(.raised(raise(.menu, m, hook: true))) }
        }
    }

    /// `a`'s dialog drawn again, maybe at another width (a resize): same reason, and the same text from a few lines above
    /// the one that shows the reason on (what the dialog asks about, then its options), once spacing, line breaks and box
    /// borders are gone; at another width those lines hold more or less of it, so one may be the end of the other.
    // ponytail: heuristic — the shorter must be at least half the longer; a question wrapped at the new width (its
    // reason no longer on one line) counts as a new prompt
    static func sameDialog(_ a: Approval, _ why: String, _ prompt: String) -> Bool {
        guard a.reason == why else { return false }
        if a.prompt == prompt { return true }
        func tail(_ s: String) -> String? {
            let lines = s.split(separator: "\n")
            guard let i = lines.lastIndex(where: { $0.range(of: why, options: .caseInsensitive) != nil }) else { return nil }
            return String(String.UnicodeScalarView(lines[max(0, i - 4)...].joined().unicodeScalars.filter {
                !$0.properties.isWhitespace && !(0x2500...0x257F).contains($0.value) && $0 != "❯" && $0 != ">" }))   // borders, cursor
        }
        guard let x = tail(a.prompt), let y = tail(prompt) else { return false }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        return !short.isEmpty && long.hasSuffix(short) && short.count * 2 >= long.count
    }

    private func restore(_ a: Approval) {   // under lock
        _pending = a; fromHook = false
        onEvent(.updated(a))
    }

    /// Claude's hook announced a permission dialog (Claude sends it only while the dialog is still open, 6 s after it
    /// appeared). Ignored when one is already pending (the screen saw it first); right after input, held until the window
    /// ends, so a dialog drawn then is not lost.
    func hookPermission(_ message: String) {
        lock.withLock {
            guard _pending == nil else { return }
            guard !quiet.unscanned else { heldHook = message; return }   // the input's window-end scan raises it
            onEvent(.raised(raise(.menu, message, hook: true)))
        }
    }

    /// The user's keys, or an unguarded ask's prompt (`echo`: its echo is not a prompt). A prompt they don't move comes
    /// back when the window ends.
    func input(echo: String? = nil) { lock.withLock { answered(echo: echo, restore: true) } }

    enum Gate: Equatable { case written, pending, window }
    /// A guarded prompt's write: counted as input only when no approval is pending and no output is waiting to be
    /// scanned, in one step (a prompt raised between a separate check and the input would be cleared, then typed into).
    func inputIfClear(echo: String) -> Gate {
        lock.withLock {
            if _pending != nil { return .pending }
            if quiet.unscanned { return .window }
            answered(echo: echo, restore: false)
            return .written
        }
    }
    /// Inputs counted so far (tests: an approval counts once, not again through the hub).
    var inputCount: Int { lock.withLock { inputs } }

    /// Approval `id` if it is still the pending prompt and still on screen; taken (answered from now on) so nothing else
    /// answers it. A stale one stays pending: only input clears it, the chat keeps refusing. `inputs`: for `reraise`.
    func take(_ id: UUID) -> (approval: Approval, inputs: Int)? {
        lock.withLock {
            guard let a = _pending, a.id == id else { return nil }
            // gone from the screen: nothing is written, and it is dropped so its card goes (`approve` says it is stale)
            guard onScreen(a) else { drop(); return nil }
            answered(echo: nil, restore: false); heldHook = nil   // R9 puts it back if the key is ignored
            return (a, inputs)
        }
    }

    /// The answer's key drew no reaction (R9: a Select in typeahead mode ignores "1"): `a` is pending again, unless
    /// there was input or another prompt since.
    func reraise(_ a: Approval, ifInputs n: Int) {
        lock.withLock {
            guard inputs == n, _pending == nil else { return }
            _pending = a; fromHook = false
            onEvent(.raised(a))
        }
    }

    /// Drops the pending approval (`id`: only that one) and writes nothing: a Stop hook (no dialog is open), or the user
    /// dismissed it (they look at the terminal themselves).
    @discardableResult
    func dismiss(_ id: UUID? = nil) -> Bool {
        lock.withLock {
            guard let a = _pending, id == nil || a.id == id else { return false }
            drop()
            return true
        }
    }

    private func drop() {   // under lock
        _pending = nil; fromHook = false; restorable = nil; heldHook = nil
        onEvent(.cleared(terminalId))
    }

    private func raise(_ kind: ApprovalKind, _ reason: String, hook: Bool) -> Approval {   // under lock
        let a = Approval(terminalId: terminalId, terminal: name, kind: kind, reason: reason, prompt: Self.capture(scrollback))
        _pending = a; fromHook = hook
        return a
    }

    private func answered(echo: String?, restore: Bool) {   // under lock
        let was = _pending
        // keys in a row: the prompt the first one cleared is the one to put back, unless a line break came after any of
        // them (`y⏎` then `ls`: answered — never brought back)
        restorable = restore ? (was ?? (quiet.unscanned && !quiet.heldHasNewline ? restorable : nil)) : nil
        quiet.input(echo: echo); _pending = nil; fromHook = false; inputs += 1
        if was != nil { onEvent(.cleared(terminalId)) }
        DispatchQueue.global().asyncAfter(deadline: QuietDetector.windowEnd) { [weak self] in self?.windowEnded() }
    }

    /// The window is over: scan what it held; an overflow is decided once the output stayed stopped.
    func windowEnded() {
        scan("")
        guard lock.withLock({ quiet.overflowArmed }) else { return }
        DispatchQueue.global().asyncAfter(deadline: QuietDetector.overflowEnd) { [weak self] in self?.overflowCheck() }
    }

    /// `QuietDetector.overflowCheck`: an overflowed window whose output stayed stopped is an `unknown` approval.
    func overflowCheck() {
        lock.withLock {
            guard _pending == nil, let why = quiet.overflowCheck() else { return }
            onEvent(.raised(raise(AttentionDetector.kind(why), why, hook: false)))
        }
    }

    private func onScreen(_ a: Approval) -> Bool {
        let block = a.prompt.split(separator: "\n").map(String.init)
        let screen = Self.lines(scrollback, Self.screenLines)
        return !block.isEmpty && block.count <= screen.count
            && (0...(screen.count - block.count)).contains { screen[$0..<($0 + block.count)].elementsEqual(block) }
    }

    static func capture(_ sb: ScrollbackBuffer) -> String { lines(sb, promptLines).joined(separator: "\n") }

    /// The last `n` non-empty lines on screen (ANSI stripped, trailing blanks trimmed).
    // ponytail: scrollback is append-only text, not a screen grid: a cursor-positioned redraw appends its frame again
    static func lines(_ sb: ScrollbackBuffer, _ n: Int) -> [String] {
        let text = sb.text(since: max(0, sb.mark() - 64 * 1024)).text
        let all = text.split(separator: "\n").map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
        return Array(all.filter { !$0.isEmpty }.suffix(n))
    }
}

/// Owns everything about inter-agent asks: per-target FIFO, deadlock graph, hook/idle completion, timeouts.
public actor AskCoordinator {
    private struct Target {
        var name: String
        var preset: Preset
        var process: PTYProcess
        var scrollback: ScrollbackBuffer
        var paste: PasteModeTracker
        var approval: ApprovalTracker
        var queue: [UUID] = []
        var inflight: (id: UUID, mark: Int)?
        var attachedAt = ContinuousClock.now
        var ready = false   // latched by the readiness poller; pump injects nothing before it
        /// Latched on the first `turn.completed`: from then on the target completes by hook only (no idle fallback).
        var hookCapable = false
        /// Last turn finished by idle before the latch; its hook may still be on its way and is not a new turn.
        var idleOwed = false
        /// Output of that idle-finished turn (tail): a hook whose message isn't in it is the current turn's, not
        /// the owed one. nil = unknown (held turn expired): swallow the next hook unconditionally.
        var owedText: String?
        /// In-flight ask during which an owed hook was swallowed without proof it was the owed one: it may have
        /// been this ask's own hook, so this turn is not held on timeout and owes nothing on cap expiry.
        var swallowedFor: UUID?
        /// A re-pump is scheduled for a user ask waiting for the agent to stop working.
        var quietPoll = false
        /// Claude's Stop may answer with a capture block: no queued ask is typed until the daemon decided, and, when it
        /// blocked, until the continued Stop (or `captureHoldMax`): the capture turn never takes, or answers, an ask.
        var captureHold: UUID?
    }
    private struct Waiter {
        var from: UUID, to: UUID, prompt: String, raw: Bool
        /// Caller resumed once written; the waiter stays in flight until its turn ends (hook/idle/hold cap)
        /// so the next queued ask isn't typed into, or completed by, the injected prompt's turn.
        var inject = false
        /// The user's ask: typed only once the target printed nothing for `StreamHub.workingWindow` (it is not
        /// working on a turn of its own), so the reply is never another turn's.
        var afterQuiet = false
        /// Never typed while the target shows an unanswered approval prompt: its Enter would answer it blindly.
        var guardsApproval = false
        /// Timed out after delivery: caller already failed; the turn still holds the slot until it ends.
        var held = false
        /// R17: the app's work chat (`askAsUser`): the user's own text.
        var user = false
        var cont: CheckedContinuation<Result<AskResult, ProtocolError>, Never>?
        var timer: Task<Void, Never>?
    }

    /// Injection readiness: a fresh terminal (login shell, agent TUI) can drop typeahead while it initialises.
    /// Ready once it printed something and then stayed quiet `readyQuiet`, or `readyMax` after attach.
    static let readyQuiet: Duration = .milliseconds(300)
    static let readyMax: Duration = .seconds(10)
    static let readyPoll: Duration = .milliseconds(50)

    private let idleQuiet: Duration
    /// R12: what the app typed into each terminal, tainted by every write made here (asks, injects, the chat).
    nonisolated let provenance = InputProvenance()
    private var targets: [UUID: Target] = [:]
    private var waiters: [UUID: Waiter] = [:]   // queued + in-flight asks; also the deadlock graph (from -> to)

    private let heldMax: Duration
    /// Every approval prompt as it appears, changes or clears (one consumer: the router tells the chat and the panels).
    nonisolated let approvalEvents: AsyncStream<ApprovalEvent>
    private nonisolated let approvalSink: AsyncStream<ApprovalEvent>.Continuation
    /// Guarded prompts held back because output after an input was not scanned yet (tests).
    private(set) var windowDeferrals = 0
    private let captureHoldMax: Duration
    public init(idleQuietSeconds: Double, heldMaxSeconds: Double = 600, captureHoldSeconds: Double = 120) {
        idleQuiet = .seconds(idleQuietSeconds); heldMax = .seconds(heldMaxSeconds); captureHoldMax = .seconds(captureHoldSeconds)
        (approvalEvents, approvalSink) = AsyncStream.makeStream(of: ApprovalEvent.self, bufferingPolicy: .bufferingNewest(100))
    }

    /// Registers a spawned terminal. Wires output (paste-mode tracking) and exit (fails its asks).
    public func attach(_ rec: TerminalRecord, process: PTYProcess, scrollback: ScrollbackBuffer) {
        let sink = approvalSink, paste = PasteModeTracker()
        let approval = ApprovalTracker(terminalId: rec.id, name: rec.name, preset: rec.preset, scrollback: scrollback) { sink.yield($0) }
        // ponytail: output read between spawn and this assignment isn't scanned; an agent enabling
        // bracketed paste within those microseconds would get plain input. Hook it in PTYProcess.init if seen.
        process.onOutput = { paste.feed($0); approval.feed($0) }
        let prov = provenance, tid = rec.id
        process.onWrite = { origin, d in if origin == .user { prov.typed(tid, d) } else { prov.taint(tid) } }   // R16
        // a prompt printed before the hook (a trust dialog at launch): scanned on the PTY queue, as the hub does
        process.serialized { approval.feed(Data(scrollback.snapshot().data.suffix(4096))) }
        targets[rec.id] = Target(name: rec.name, preset: rec.preset, process: process, scrollback: scrollback, paste: paste,
                                 approval: approval)
        let id = rec.id, me = ObjectIdentifier(process)
        // replays if already exited; ignored once the terminal was replaced by a new launch with the same id
        let prevExit = process.onExit
        process.onExit = { [weak self] code in prevExit?(code); Task { await self?.exited(id, me) } }
        // ponytail: 50 ms sampling may miss a quiet window shorter than readyQuiet + readyPoll
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.readyPoll)
                guard let self, await self.pollReady(id, me) else { return }
            }
        }
    }

    public func ask(from: UUID, to: UUID, prompt: String, raw: Bool, timeout: Duration) async throws(ProtocolError) -> AskResult {
        guard let t = targets[to], t.process.isRunning else {
            throw ProtocolError(code: .notRunning, message: "Terminal '\(targets[to]?.name ?? to.uuidString)' is not running")
        }
        if reaches(to, from) {
            throw ProtocolError(code: .deadlock,
                                message: "Deadlock: '\(t.name)' is already waiting on '\(name(from))'; '\(name(from))' cannot ask '\(t.name)'")
        }
        // R7: unguarded on purpose — v1 asks answer prompts (a Shepherd's `collie ask B y`)
        return try await enqueue(Waiter(from: from, to: to, prompt: prompt, raw: raw, cont: nil), timeout: timeout)
    }

    /// The user's ask (work chat): same FIFO, readiness gate and hook/idle completion as `ask`, but no caller
    /// terminal, so no edge in the deadlock graph (`from == to`, as `inject`).
    public func askAsUser(to: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult {
        guard let t = targets[to], t.process.isRunning else {
            throw ProtocolError(code: .notRunning, message: "Terminal '\(targets[to]?.name ?? to.uuidString)' is not running")
        }
        return try await enqueue(Waiter(from: to, to: to, prompt: prompt, raw: false, afterQuiet: true, guardsApproval: true, user: true, cont: nil),
                                 timeout: timeout)
    }

    /// Types `prompt` into `to` through the same readiness gate and FIFO as `ask`; returns once written,
    /// not when the turn ends. The turn still holds the queue, up to `hold`.
    public func inject(to: UUID, prompt: String, hold: Duration = .seconds(1800)) async throws(ProtocolError) {
        guard let t = targets[to], t.process.isRunning else {
            throw ProtocolError(code: .notRunning, message: "Terminal '\(targets[to]?.name ?? to.uuidString)' is not running")
        }
        // from == to: adds no edge to the deadlock graph
        // R10: never typed into a pending approval prompt (a summon's first prompt, a herd role)
        _ = try await enqueue(Waiter(from: to, to: to, prompt: prompt, raw: false, inject: true, guardsApproval: true, cont: nil),
                              timeout: hold)
    }

    private func enqueue(_ waiter: Waiter, timeout: Duration) async throws(ProtocolError) -> AskResult {
        let id = UUID(), to = waiter.to
        let r = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Result<AskResult, ProtocolError>, Never>) in
                var w = waiter
                w.cont = c
                w.timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.timedOut(id, after: timeout)
                }
                waiters[id] = w
                targets[to]?.queue.append(id)
                if Task.isCancelled { finish(id, .failure(cancelled)) } else { pump(to) }
            }
        } onCancel: {
            Task { await self.abandon(id, ProtocolError(code: .internal, message: "ask cancelled")) }
        }
        return try r.get()
    }

    /// Hook: the terminal's agent finished its turn. No in-flight ask -> no-op.
    public func turnCompleted(terminal: UUID, message: String?) {
        guard var t = targets[terminal] else { return }
        t.approval.dismiss()   // the turn ended: no dialog is open
        t.hookCapable = true
        // the first hook after idle-finished turns belongs to the last of them, not to the in-flight ask
        // ponytail: a Bool, not a count: a lost/coalesced hook or a hookless stretch costs at most one
        // timed-out ask. The latch is permanent for the life of the process: a plain shell that once sent
        // a hook stays hook-only (no idle fallback) until it is respawned.
        if t.idleOwed {
            t.idleOwed = false
            let owed = t.owedText
            t.owedText = nil
            let sig = message.map(Self.signature) ?? ""
            if !sig.isEmpty, let owed, owed.contains(sig) {
                targets[terminal] = t; return            // provably the idle turn's late hook
            }
            // the current turn's own answer, searched after its prompt's echo (a prompt may quote the old answer);
            // unknown owed turn (cap expiry) -> never "mine": its late answer is drawn after this mark too
            let mine = owed != nil && !sig.isEmpty && t.inflight.map { cur in
                let text = t.scrollback.text(since: cur.mark).text
                let echo = waiters[cur.id].map { Self.signature($0.prompt) } ?? ""
                // echo not found (TUI wrapped/decorated it): can't tell -> not mine (swallow, bounded)
                guard !echo.isEmpty, let r = text.range(of: echo, options: .backwards) else { return false }
                return text[r.upperBound...].contains(sig)
            } == true
            if !mine {                                   // can't tell: swallow (bounded: costs at most one ask)
                t.swallowedFor = t.inflight?.id
                targets[terminal] = t; return
            }
        }
        targets[terminal] = t
        guard let (id, mark) = t.inflight else { return }
        if let message { finish(id, .success(AskResult(output: message, source: .hook, truncated: false))) }
        else {
            let s = t.scrollback.text(since: mark)
            finish(id, .success(AskResult(output: s.text, source: .hook, truncated: s.truncated)))
        }
    }

    /// A Stop hook made the agent go on (Claude's `stop_hook_active`): no dialog is open; the capture turn it ran is
    /// over, so a held queue goes on. Its reply completes no ask.
    public func turnContinued(terminal: UUID) {
        targets[terminal]?.approval.dismiss()
        if let h = targets[terminal]?.captureHold { releaseCapture(terminal, h) }
    }

    /// Before Claude's Stop is reported: holds `terminal`'s queue until `releaseCapture` (no block) or the continued Stop.
    func holdForCapture(_ terminal: UUID) -> UUID? {
        guard targets[terminal] != nil else { return nil }
        let h = UUID()
        targets[terminal]?.captureHold = h
        return h
    }

    /// The daemon blocked the Stop: the hold lasts until the continued Stop, at most `captureHoldMax`.
    func captureBlocked(_ terminal: UUID, _ hold: UUID) {
        let cap = captureHoldMax
        Task { [weak self] in
            try? await Task.sleep(for: cap)
            await self?.releaseCapture(terminal, hold)
        }
    }

    /// Ends hold `hold` (a later one stays) and types the next queued ask.
    func releaseCapture(_ terminal: UUID, _ hold: UUID) {
        guard targets[terminal]?.captureHold == hold else { return }
        targets[terminal]?.captureHold = nil
        pump(terminal)
    }

    /// Fails the in-flight ask and every queued ask for this terminal.
    public func processExited(_ terminal: UUID) {
        guard let t = targets[terminal] else { return }
        let err = ProtocolError(code: .notRunning, message: "Terminal '\(t.name)' exited")
        // queued first: finishing the in-flight one would otherwise pump the next prompt into a dead terminal
        for id in t.queue + [t.inflight?.id].compactMap({ $0 }) { finish(id, .failure(err)) }
    }

    /// Kill/replace: fails the terminal's asks, then forgets it.
    public func detach(_ terminal: UUID) {
        processExited(terminal)
        targets[terminal] = nil
    }
    /// The readiness that holds a fresh terminal's first prompt: true once latched; false if the process is gone or
    /// `timeout` passes first.
    public func waitReady(_ id: UUID, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while let t = targets[id], t.process.isRunning {
            if t.ready { return true }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: Self.readyPoll)
        }
        return false
    }
    var targetCount: Int { targets.count }
    /// An ask is in flight for `terminal` (status badge).
    func isBusy(_ terminal: UUID) -> Bool { targets[terminal]?.inflight != nil }

    /// Latches readiness and pumps queued asks; false stops the poller (ready, exited, or replaced).
    private func pollReady(_ terminal: UUID, _ process: ObjectIdentifier) -> Bool {
        guard let t = targets[terminal], ObjectIdentifier(t.process) == process, t.process.isRunning else { return false }
        let now = ContinuousClock.now
        let quiet = t.process.lastOutputAt.map { now - $0 >= Self.readyQuiet } ?? false
        guard quiet || now - t.attachedAt >= Self.readyMax else { return true }
        targets[terminal]?.ready = true
        pump(terminal)
        return false
    }

    private func timedOut(_ id: UUID, after timeout: Duration) {
        guard let w = waiters[id] else { return }   // already finished
        if w.held {   // cap reached: free the slot; owe its hook unless one may already have been it
            if targets[w.to]?.swallowedFor != id { targets[w.to]?.idleOwed = true; targets[w.to]?.owedText = nil }
            finish(id, .failure(ProtocolError(code: .timeout, message: "held turn expired")))
            return
        }
        let t = targets[w.to], name = name(w.to)
        let message = if let t, t.queue.contains(id), !t.ready {
            t.process.lastOutputAt == nil ? "'\(name)' produced no output yet; prompt not delivered"
                                          : "'\(name)' is not ready yet (no quiet period); prompt not delivered"
        } else if let t, t.queue.contains(id), t.inflight != nil {
            "'\(name)' is still busy with an earlier turn; prompt not delivered"
        } else if let t, t.queue.contains(id), w.afterQuiet {
            "'\(name)' is still working; prompt not delivered"
        } else { "No reply from '\(name)' within \(timeout.components.seconds)s" }
        abandon(id, ProtocolError(code: .timeout, message: message))
    }

    /// The caller gives up (timeout/cancel). Delivered and still running: fail the caller now but keep the slot
    /// until the turn ends (hook, idle, exit or heldMax). Freeing it would type the next prompt into the busy
    /// agent and hand this turn's late hook to that ask, shifting every later answer by one.
    private func abandon(_ id: UUID, _ err: ProtocolError) {
        guard var w = waiters[id], !w.held else { return }   // already held: a late cancel changes nothing
        guard targets[w.to]?.inflight?.id == id, !w.inject else { finish(id, .failure(err)); return }
        w.timer?.cancel()
        w.cont?.resume(returning: .failure(err))
        w.cont = nil
        w.held = true
        w.from = w.to   // the caller stopped waiting: no deadlock edge
        let cap = heldMax
        w.timer = Task { [weak self] in
            try? await Task.sleep(for: cap)
            await self?.timedOut(id, after: cap)
        }
        waiters[id] = w
        // A hook swallowed during this flight may have been this turn's own: release once the agent goes quiet
        // (agents print while working) instead of waiting for the cap.
        // ponytail: ceiling — a truly silent working agent released early shifts answers by one until a lost
        // hook or a restart realigns them; owing a hook here instead would bring back chained failures.
        guard targets[w.to]?.swallowedFor == id else { return }
        let quiet = idleQuiet * 2
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, await self.releaseIfQuiet(id, quiet) else { return }
            }
        }
    }

    /// Held ambiguous turn: frees the slot once output has been quiet `quiet`; false stops the poller.
    private func releaseIfQuiet(_ id: UUID, _ quiet: Duration) -> Bool {
        guard let w = waiters[id], w.held, let t = targets[w.to], t.inflight?.id == id else { return false }
        guard let last = t.process.lastOutputAt, ContinuousClock.now - last >= quiet else { return true }
        finish(id, .failure(ProtocolError(code: .timeout, message: "held turn released (quiet)")))
        return false
    }

    private func exited(_ terminal: UUID, _ process: ObjectIdentifier) {
        guard let t = targets[terminal], ObjectIdentifier(t.process) == process else { return }
        processExited(terminal)
    }

    // MARK: - internals

    /// Last non-empty line of a hook message (bounded): what an idle turn's screen output must contain for
    /// that hook to be the idle turn's own.
    static func signature(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).last { !$0.allSatisfy(\.isWhitespace) }
        return String((line ?? "").trimmingCharacters(in: .whitespaces).suffix(200))
    }

    private var cancelled: ProtocolError { ProtocolError(code: .internal, message: "ask cancelled") }
    private func name(_ id: UUID) -> String { targets[id]?.name ?? id.uuidString }

    /// True if `a` already waits (directly or transitively) on `b`.
    private func reaches(_ a: UUID, _ b: UUID) -> Bool {
        var seen: Set<UUID> = [], stack = [a]
        while let n = stack.popLast() {
            if n == b { return true }
            guard seen.insert(n).inserted else { continue }
            stack += waiters.values.filter { $0.from == n }.map(\.to)
        }
        return false
    }

    /// Every completion path (success, timeout, error, exit, cancel) goes through here.
    private func finish(_ id: UUID, _ r: Result<AskResult, ProtocolError>) {
        guard let w = waiters.removeValue(forKey: id) else { return }
        w.timer?.cancel()
        if targets[w.to]?.inflight?.id == id { targets[w.to]?.inflight = nil }
        targets[w.to]?.queue.removeAll { $0 == id }
        w.cont?.resume(returning: r)
        pump(w.to)
    }

    /// Starts the next queued ask for `to` if it is ready for injection and its slot is free.
    private func pump(_ to: UUID) {
        guard let t = targets[to], t.ready, t.inflight == nil, t.captureHold == nil, let id = t.queue.first, let w = waiters[id] else { return }
        if w.guardsApproval, t.approval.pending != nil { finish(id, .failure(Self.awaitingApproval(t.name))); return }
        // output after an input not scanned yet may hold a prompt `pending` doesn't show: wait for the scan
        let unscanned = w.guardsApproval && t.approval.inWindow
        if unscanned { windowDeferrals += 1 }
        if unscanned || w.afterQuiet && t.process.lastOutputAt.map({ ContinuousClock.now - $0 < StreamHub.workingWindow }) == true {
            // ponytail: 100 ms polling of lastOutputAt (what the hub's `working` badge reads); bounded by the waiter's timeout
            guard !t.quietPoll else { return }
            targets[to]?.quietPoll = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                await self?.repump(to)
            }
            return
        }
        targets[to]?.queue.removeFirst()
        let mark = t.scrollback.mark()
        targets[to]?.inflight = (id, mark)
        targets[to]?.swallowedFor = nil
        // PTYProcess.write may spin up to 2 s on a target that isn't reading: keep it off the actor and
        // off the cooperative pool, report failures back through finish.
        let data = PromptInjector.payload(w.prompt, raw: w.raw, bracketed: t.paste.enabled)
        let process = t.process, name = t.name, inject = w.inject, approval = t.approval, guards = w.guardsApproval
        DispatchQueue.global().async { [weak self] in
            // checked again at the write, in one step with counting the input: a prompt printed (or keys typed) since the
            // check above is not answered either
            // ponytail: a prompt printed between this check and the write itself (microseconds) still is
            if guards {
                switch approval.inputIfClear(echo: w.prompt) {   // its echo is not a prompt
                case .written: break
                case .pending: Task { await self?.finish(id, .failure(Self.awaitingApproval(name))) }; return
                case .window: Task { await self?.requeue(id) }; return
                }
            } else { approval.input(echo: w.prompt) }
            do {
                try process.write(data, origin: w.user ? .user : .collie)   // R17: the user's own chat text is theirs
                if inject { Task { await self?.delivered(id) } }
            } catch {
                let e = (error as? PTYError) == .stalled
                    ? ProtocolError(code: .timeout, message: "target '\(name)' is not accepting input")
                    : ProtocolError(code: .notRunning, message: "Terminal '\(name)' is not running")
                Task { await self?.finish(id, .failure(e)) }
            }
        }
        // claude/codex, and any terminal that ever sent a hook: hook only
        guard t.preset == .shell || t.preset == .custom, !t.hookCapable else { return }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, await self.pollIdle(to, id) else { return }
            }
        }
    }

    static func awaitingApproval(_ name: String) -> ProtocolError {
        ProtocolError(code: .unavailable, message: "'\(name)' is waiting for an approval; prompt not delivered")
    }

    /// Its write found output not scanned yet: back to the head of the queue, written after the scan (or refused).
    private func requeue(_ id: UUID) {
        guard let to = waiters[id]?.to, targets[to]?.inflight?.id == id else { return }
        targets[to]?.inflight = nil
        targets[to]?.queue.insert(id, at: 0)
        pump(to)
    }

    /// `terminal`'s approval tracker: the hub tells it of the user's keys synchronously (`Fanout.onInput`).
    func approvalTracker(_ terminal: UUID) -> ApprovalTracker? { targets[terminal]?.approval }

    /// `terminal` enabled bracketed paste: a pasted block stays one prompt instead of running line by line.
    func pasteEnabled(_ terminal: UUID) -> Bool { targets[terminal]?.paste.enabled ?? false }

    /// Claude Code's `Notification` hook announced a permission dialog in `terminal`.
    func hookPermission(_ terminal: UUID, message: String) { targets[terminal]?.approval.hookPermission(message) }

    /// Asks waiting in `terminal`'s queue (tests).
    func queued(_ terminal: UUID) -> Int { targets[terminal]?.queue.count ?? 0 }

    func approvalInputs(_ terminal: UUID) -> Int { targets[terminal]?.approval.inputCount ?? 0 }

    func hasPendingApproval(_ terminal: UUID) -> Bool { pendingApproval(terminal) != nil }

    /// Pending approval prompts, oldest first.
    func approvals() -> [Approval] {
        targets.values.filter(\.process.isRunning).compactMap(\.approval.pending).sorted { $0.at < $1.at }
    }

    /// `work.approval.dismiss`: drops approval `id`, writing nothing; false if it is not pending.
    func dismissApproval(_ id: UUID) -> Bool { targets.values.contains { $0.approval.dismiss(id) } }

    static let answerReaction: Double = 2
    /// `unknown`: an approval of kind `.unknown`, which nothing answers but the user's own keys (still pending).
    enum Answer: Sendable, Equatable { case stale, unknown, sent(Approval), dismissed(Approval), failed(Approval) }

    /// Answers approval `id`: the keys are written only if it is still its terminal's pending prompt, on screen, at the
    /// moment of writing; otherwise `.stale` and nothing is written. `dismissed`: a denied "press enter" (nothing to type).
    func approve(_ id: UUID, allow: Bool) async -> Answer {
        let candidates = targets.values.map { ($0.approval, $0.process, $0.scrollback) }
        return await withCheckedContinuation { c in
            // scrollback decode and PTYProcess.write (may spin 2 s): off the actor and the cooperative pool
            DispatchQueue.global().async {
                // ponytail: a prompt printed between take and write (microseconds) is answered with these keys
                if candidates.contains(where: { $0.0.pending.map { $0.id == id && $0.kind == .unknown } == true }) {
                    return c.resume(returning: .unknown)
                }
                var hit: (ApprovalTracker, Approval, Int, PTYProcess, ScrollbackBuffer)?
                for (t, p, sb) in candidates where hit == nil { hit = t.take(id).map { (t, $0.approval, $0.inputs, p, sb) } }   // take has a side effect: once each
                guard let (tracker, a, inputs, process, sb) = hit else { return c.resume(returning: .stale) }
                guard let keys = Self.keys(a.kind, allow: allow) else { return c.resume(returning: .dismissed(a)) }
                let before = sb.mark()
                // the user's click in the app (approvals are answered only from the app's work chat)
                do { try process.write(keys, origin: .user); c.resume(returning: .sent(a)) } catch { return c.resume(returning: .failed(a)) }
                // R9: a dialog that took the key redraws (or echoes); no output at all means the key was ignored
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.answerReaction) { [weak self] in
                    guard sb.mark() == before else { return }
                    Task { await self?.reraise(tracker, a, ifInputs: inputs) }
                }
            }
        }
    }

    /// R9 re-raise, unless the terminal exited or was relaunched (a new tracker) since.
    private func reraise(_ tracker: ApprovalTracker, _ a: Approval, ifInputs n: Int) {
        guard let t = targets[a.terminalId], t.approval === tracker, t.process.isRunning else { return }
        tracker.reraise(a, ifInputs: n)
    }

    func pendingApproval(_ terminal: UUID) -> Approval? { targets[terminal]?.approval.pending }

    /// What answers a prompt of `kind`; nil: nothing (a denied "press enter" is only dismissed; `unknown` never).
    static func keys(_ kind: ApprovalKind, allow: Bool) -> Data? {
        switch kind {
        case .unknown: nil
        case .yesNo: Data((allow ? "y\r" : "n\r").utf8)
        // the digit picks option 1 ("Yes") wherever the cursor is (Claude's Select maps 1-9 to options); Esc is "No"
        case .menu: Data((allow ? "1" : "\u{1B}").utf8)
        case .enter: allow ? Data("\r".utf8) : nil
        }
    }

    private func repump(_ to: UUID) { targets[to]?.quietPoll = false; pump(to) }

    /// Inject written: resume its caller now; the waiter keeps the slot until its turn ends.
    private func delivered(_ id: UUID) {
        waiters[id]?.cont?.resume(returning: .success(AskResult(output: "", source: .hook, truncated: false)))
        waiters[id]?.cont = nil
    }

    /// Idle fallback; returns false once `id` is no longer in flight (stops the poller).
    private func pollIdle(_ to: UUID, _ id: UUID) -> Bool {
        guard let t = targets[to], let (cur, mark) = t.inflight, cur == id, !t.hookCapable else { return false }
        guard t.scrollback.mark() > mark, let last = t.process.lastOutputAt,
              ContinuousClock.now - last >= idleQuiet else { return true }
        let s = t.scrollback.text(since: mark)
        targets[to]?.idleOwed = true   // never consumed if the target really has no hook
        targets[to]?.owedText = String(s.text.suffix(64 * 1024))
        finish(id, .success(AskResult(output: s.text, source: .idle, truncated: s.truncated)))
        return false
    }
}
