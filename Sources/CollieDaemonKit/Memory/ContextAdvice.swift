import Foundation

/// M5.5: a Shepherd whose transcript passed `threshold` is told, once every `every`, that each turn rereads it and a new
/// session would be cheaper. Only the file's size is looked at (`stat` of a path `TranscriptChunk.allowed` accepts: a
/// regular `.jsonl` under the agent's projects dir, no symlink, no FIFO); its content is never read nor quoted.
enum ContextAdvice {
    static let threshold: UInt64 = 20 << 20
    static let every: TimeInterval = 2 * 3600

    /// The advice line: fixed text, only the size (whole MB) varies.
    static func line(megabytes: UInt64) -> String {
        "Contexto grande (\(megabytes) MB): cada turno relê ~esse contexto. Considere uma sessão nova; as decisões estão na memória e nos docs."
    }

    /// The transcript's size in bytes, or nil when the path is not allowed or cannot be measured.
    static func size(_ path: String, projectsDir: URL) -> UInt64? {
        guard let url = TranscriptChunk.allowed(path, projectsDir: projectsDir) else { return nil }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size >= 0 else { return nil }
        return UInt64(st.st_size)
    }

    /// The advice for this Stop, or nil: not a Shepherd, the memory ask goes out this Stop (one text per Stop), advised
    /// less than `every` ago, small transcript, or any failure to measure.
    static func advice(transcript: String?, projectsDir: URL, isShepherd: Bool, memoryAsked: Bool, last: Date?, now: Date) -> String? {
        guard isShepherd, !memoryAsked, let transcript else { return nil }
        if let last, now.timeIntervalSince(last) < every { return nil }
        guard let bytes = size(transcript, projectsDir: projectsDir), bytes > threshold else { return nil }
        return line(megabytes: bytes >> 20)
    }
}

extension CommandRouter {
    /// M5.5: `ContextAdvice.advice` for `tid`'s Stop, its clock per terminal (`contextAdvisedAt`). Never fails.
    func contextAdvice(_ tid: UUID, transcript: String?, memoryAsked: Bool, now: Date = Date()) async -> String? {
        guard let me = ws.terminals.first(where: { $0.id == tid }) else { return nil }
        let dir = await projectsDir(me)
        guard let a = ContextAdvice.advice(transcript: transcript, projectsDir: dir, isShepherd: me.isShepherd,
                                           memoryAsked: memoryAsked, last: contextAdvisedAt[tid], now: now) else { return nil }
        contextAdvisedAt[tid] = now
        return a
    }
}
