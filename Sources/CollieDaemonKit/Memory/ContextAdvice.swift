import Foundation
import CollieCore

/// M5.5, M10.1: a Shepherd whose context passed `warn` (or `strong`) tokens is told that each turn rereads it and that a
/// new session starts from the handoff (`collie work handoff`). The context is the last call's: input + cache written +
/// cache read of the last assistant `usage` in the transcript's tail (at most `tailMax` bytes, of a path
/// `TranscriptChunk.allowed` accepts: a regular `.jsonl` under the agent's projects dir, no symlink, no FIFO). Only those
/// numbers are kept; no text is ever kept nor quoted. Once per level every `every`; a higher level goes out at once.
enum ContextAdvice {
    static let warn = 150_000, strong = 250_000
    static let every: TimeInterval = 2 * 3600
    static let tailMax: UInt64 = 256 << 10

    /// When the advice last went out and at which level (1: warn, 2: strong).
    struct Advised: Equatable, Sendable { var at: Date; var level: Int }

    static func level(_ tokens: Int) -> Int { tokens >= strong ? 2 : tokens >= warn ? 1 : 0 }

    /// The advice line: fixed text per level, only the number (whole thousands) varies.
    static func line(tokens: Int, level: Int) -> String {
        let k = tokens / 1000
        return level >= 2
            ? "Contexto muito grande (\(k) mil tokens): cada turno relê esse contexto. Abra uma sessão nova agora e leia a passagem de turno: collie work handoff."
            : "Contexto grande (\(k) mil tokens): cada turno relê esse contexto. Considere uma sessão nova e leia a passagem de turno: collie work handoff."
    }

    /// The last call's context in tokens, from the transcript's tail; nil: the path is not allowed, it cannot be read, or
    /// no call with usage is in the tail. Sidechain lines are not the session's own context.
    static func lastContext(_ path: String, projectsDir: URL) -> Int? {
        guard let url = TranscriptChunk.allowed(path, projectsDir: projectsDir) else { return nil }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size >= 0 else { return nil }
        let size = UInt64(st.st_size), from = size > tailMax ? size - tailMax : 0
        var last: Int?
        // the first line of the tail may be cut: it is not JSON and is skipped
        guard TranscriptChunk.lines(url, from: from, maxBytes: 2 * tailMax, { raw in
            guard let e = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], e["type"] as? String == "assistant",
                  e["isSidechain"] as? Bool != true,
                  let msg = e["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return }
            func n(_ k: String) -> Int { max(0, (u[k] as? NSNumber)?.intValue ?? 0) }
            let c = n("input_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens")
            if c > 0 { last = c }
        }) != nil else { return nil }
        return last
    }

    /// What to record when the advice goes out this Stop, or nil: not a Shepherd, the memory ask goes out this Stop (one
    /// text per Stop), no number, under `warn`, or the same (or a lower) level advised less than `every` ago.
    static func decide(tokens: Int?, isShepherd: Bool, memoryAsked: Bool, last: Advised?, now: Date) -> Advised? {
        guard isShepherd, !memoryAsked, let tokens else { return nil }
        let l = level(tokens)
        guard l > 0 else { return nil }
        if let last, l <= last.level, now.timeIntervalSince(last.at) < every { return nil }
        return Advised(at: now, level: l)
    }
}

extension CommandRouter {
    /// M5.5, M10.1: `ContextAdvice` for the Shepherd `tid`'s Stop, its clock per terminal (`contextAdvisedAt`). The
    /// measured context is logged (`pastorContext`, numbers only) for `memory stats`. Never fails.
    func contextAdvice(_ tid: UUID, transcript: String?, memoryAsked: Bool, now: Date = Date()) async -> String? {
        guard let me = ws.terminals.first(where: { $0.id == tid }), me.isShepherd, !memoryAsked, let transcript else { return nil }
        let dir = await projectsDir(me)
        guard let tokens = try? await UnixSocketClient.offPool({ ContextAdvice.lastContext(transcript, projectsDir: dir) }) else { return nil }
        let session = URL(fileURLWithPath: transcript).deletingPathExtension().lastPathComponent
        memory.events.emit(MemoryEvent(type: .pastorContext, terminal: tid, session: session, project: await memory.repo(for: me.cwd).root?.path,
                                       tokens: tokens))
        guard let a = ContextAdvice.decide(tokens: tokens, isShepherd: true, memoryAsked: false, last: contextAdvisedAt[tid], now: now) else { return nil }
        contextAdvisedAt[tid] = a
        return ContextAdvice.line(tokens: tokens, level: a.level)
    }
}
