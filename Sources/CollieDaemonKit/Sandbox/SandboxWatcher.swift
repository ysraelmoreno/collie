import Foundation
import CollieCore

/// Sees the sandbox's denials (Task 1): one `/usr/bin/log stream` child of the daemon, as the user, filtered on the
/// tag every deny rule of a terminal's profile carries (`collie-term:<id>`). The tag maps a line to its terminal (no
/// pid lookup: short-lived pids are gone before their line arrives).
///
/// Startup race: `log stream` takes ~1-2 s to attach, and a denial before that is never seen (the deny itself is
/// always enforced). The daemon starts the watcher right after binding its socket, before any terminal can launch
/// (no request authenticates until the admin token is written, later in `start`). A terminal's id is known from the
/// moment its profile is rendered (`prepareSandbox`), before its process exists, so its first denial isn't dropped.
/// The kernel also collapses repeats ("N duplicate reports") and drops a few % in storms: cards are best effort.
enum SandboxWatcher {
    /// R28: the kernel's reports only (`processID == 0`): a userland image named `Sandbox` can't forge cards.
    static let predicate = #"sender == "Sandbox" AND processID == 0 AND eventMessage CONTAINS "\#(SandboxProfile.tagPrefix)""#

    struct Line: Equatable { var terminal: UUID; var op: String; var path: String; var count: Int }

    /// One ndjson line of the stream → its denial, or nil (not a denial, no tag, an op that raises no card).
    /// `eventMessage` is `Sandbox: <proc>(<pid>) deny(1) <op> <path>` (or `Sandbox: <proc>(<pid>) N duplicate reports
    /// for … deny(1) <op> <path>`), then `\n<tag>`. Only the **final** line is the tag: a path may hold newlines, and a
    /// planted `\ncollie-term:<other id>` in it stays part of the path (R5).
    static func parse(_ ndjson: String) -> Line? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(ndjson.utf8)) as? [String: Any],
              let msg = obj["eventMessage"] as? String,
              (obj["processID"] as? Int).map({ $0 == 0 }) ?? true else { return nil }   // R28: kernel only
        var lines = msg.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        guard lines.count >= 2, let tag = lines.popLast()?.trimmingCharacters(in: .whitespaces),
              tag.hasPrefix(SandboxProfile.tagPrefix),
              let id = UUID(uuidString: String(tag.dropFirst(SandboxProfile.tagPrefix.count))) else { return nil }
        let head = lines.joined(separator: "\n")
        guard head.hasPrefix("Sandbox: "), let deny = head.range(of: #" deny\(\d+\) "#, options: .regularExpression) else { return nil }
        let rest = head[deny.upperBound...]
        guard let sp = rest.firstIndex(of: " ") else { return nil }
        let path = String(rest[rest.index(after: sp)...])
        guard path.hasPrefix("/"), let op = card(op: String(rest[..<sp])) else { return nil }
        var count = 1
        if let r = head.range(of: #"\d+ duplicate report"#, options: .regularExpression),
           let n = Int(head[r].prefix { $0.isNumber }) { count = n }
        return Line(terminal: id, op: op, path: path, count: count)
    }

    /// Seatbelt's operation → the card's verb. ponytail: signals, sockets and link checks raise no card (not grantable).
    static func card(op: String) -> String? {
        if op.hasPrefix("file-read") { return "read" }
        if op == "file-write-unlink" { return "delete" }
        if op.hasPrefix("file-write") { return "write" }
        if op.hasPrefix("process-exec") { return "exec" }
        return nil
    }

    /// Runs `source` and restarts it whenever it ends, with backoff (`base` doubling to `max`, reset after a minute of
    /// running). `state(true)` when a run starts, `state(false)` when it ends ("detecção indisponível"). Until cancelled.
    static func supervise(source: @escaping @Sendable () -> AsyncStream<String>, base: Duration, max: Duration,
                          state: @escaping @Sendable (Bool) async -> Void, line: @escaping @Sendable (Line) async -> Void) async {
        var delay = base
        while !Task.isCancelled {
            let started = ContinuousClock.now
            await state(true)
            for await l in source() { if let d = parse(l) { await line(d) } }
            await state(false)
            if ContinuousClock.now - started > .seconds(60) { delay = base }
            try? await Task.sleep(for: delay)
            delay = Swift.min(delay * 2, max)
        }
    }

    private final class Child: @unchecked Sendable { let p = Process() }   // terminated from onTermination only

    /// The live source: `log stream --style ndjson`, one line per element (bounded: the newest 4096 kept). Ends when
    /// the child exits or can't start; the stream's end (cancellation included) terminates the child.
    @Sendable static func logStream() -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4096)) { cont in
            let c = Child(), pipe = Pipe()
            c.p.executableURL = URL(fileURLWithPath: "/usr/bin/log")   // not zsh's `log` builtin
            c.p.arguments = ["stream", "--style", "ndjson", "--predicate", predicate]
            c.p.standardOutput = pipe; c.p.standardError = FileHandle.nullDevice; c.p.standardInput = FileHandle.nullDevice
            do { try c.p.run() } catch { cont.finish(); return }
            cont.onTermination = { _ in if c.p.isRunning { c.p.terminate() } }
            let h = pipe.fileHandleForReading
            Thread {
                var buf = Data()
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    buf.append(d)
                    while let i = buf.firstIndex(of: 10) {
                        cont.yield(String(decoding: buf[buf.startIndex..<i], as: UTF8.self))
                        buf.removeSubrange(buf.startIndex...i)
                    }
                    if buf.count > 1 << 20 { buf.removeAll() }   // a runaway line: dropped
                }
                c.p.waitUntilExit()
                cont.finish()
            }.start()
        }
    }
}

/// The pending cards: one per (terminal, op, folder), bounded — at most `perTerminal` open cards a terminal (more new
/// folders are counted in `dropped`, not shown), an open card re-sent at most every `updateEvery` with its count.
/// Denied keys stay quiet until that terminal goes (bounded too).
struct SandboxCards {
    static let perTerminal = 20, updateEvery: TimeInterval = 2, deniedCap = 2000
    struct Key: Hashable { var terminal: UUID; var op: String; var folder: String }
    private(set) var cards: [Key: SandboxDenial] = [:]
    private var lastSent: [Key: Date] = [:]
    private var open: [UUID: Int] = [:]
    private var denied: Set<Key> = []
    private(set) var dropped = 0

    static func key(_ d: SandboxDenial) -> Key { Key(terminal: d.terminal, op: d.op, folder: d.folder) }

    /// Records `d`; returns the card to send to the app, nil when quiet (deduped, rate-limited, over the cap, denied).
    /// `decorate` fills a new card that will be shown: it runs only then, never per storm line.
    mutating func add(_ d: SandboxDenial, now: Date = Date(), decorate: (inout SandboxDenial) -> Void = { _ in }) -> SandboxDenial? {
        var d = d
        let k = Self.key(d)
        guard !denied.contains(k) else { return nil }
        if var c = cards[k] {
            c.count += d.count; c.at = d.at
            // R29: a request never replaces the card's path (what Liberar opens), and shares the rate limit
            if d.requested { c.requested = true; c.reason = d.reason }
            cards[k] = c
            guard now.timeIntervalSince(lastSent[k] ?? .distantPast) >= Self.updateEvery else { return nil }
            lastSent[k] = now
            return c
        }
        guard open[d.terminal, default: 0] < Self.perTerminal else { dropped += 1; return nil }
        decorate(&d)
        cards[k] = d; lastSent[k] = now; open[d.terminal, default: 0] += 1
        return d
    }

    mutating func remove(_ k: Key) {
        guard cards.removeValue(forKey: k) != nil else { return }
        lastSent[k] = nil; open[k.terminal, default: 1] -= 1
    }

    /// **Negar**: the card goes, and that (terminal, op, folder) raises none again while the terminal lives.
    mutating func deny(_ k: Key) {
        remove(k)
        if denied.count >= Self.deniedCap { denied.removeAll() }   // ponytail: forgets old denials rather than growing
        denied.insert(k)
    }

    /// The cards of `terminal` that `grant` covers go (it was opened).
    mutating func removeCovered(terminal: UUID, by grant: SandboxGrant) {
        for (k, c) in cards where k.terminal == terminal && ProjectRoot.contains(c.path, root: URL(fileURLWithPath: grant.path))
            && (grant.access == .write || c.access == .read) { remove(k) }
    }

    mutating func forget(terminal: UUID) {
        for k in cards.keys where k.terminal == terminal { remove(k) }
        denied = denied.filter { $0.terminal != terminal }
        open[terminal] = nil
    }

    var all: [SandboxDenial] { cards.values.sorted { $0.at < $1.at } }
}
