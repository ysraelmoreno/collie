import Foundation
import CollieCore
import CollieProtocol

/// A Claude session's token usage, from its transcript: each assistant message's `usage` (input, output, cache read,
/// cache creation) and model. Only numbers are read — never a message's text. The path rules are `TranscriptChunk`'s (a
/// regular `.jsonl` under `<config>/projects`, no symlink, only the path the terminal's own hook named); each line is read
/// once (a per-transcript byte mark in `<root>/metrics/usage-marks.json`).
enum SessionUsage {
    struct Total: Equatable, Sendable { var input = 0, output = 0, cacheRead = 0, cacheCreation = 0, messages = 0 }

    /// Per model, the assistant messages in the complete lines after `offset`, and where they end. Claude writes a line per
    /// content block, each with its message's usage: an id counts once. ponytail: once per read — a message split across
    /// two reads (a Stop mid-write) would count twice; a Stop comes after the turn is written.
    /// `last`: the model of the last counted message (what the session runs now).
    static func read(_ url: URL, from offset: UInt64, maxBytes: UInt64 = .max) -> (byModel: [String: Total], end: UInt64, last: String?)? {
        var seen = Set<String>(), out: [String: Total] = [:], last: String?
        guard let end = TranscriptChunk.lines(url, from: offset, maxBytes: maxBytes, { raw in
            guard let e = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], e["type"] as? String == "assistant",
                  let msg = e["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] else { return }
            if let id = msg["id"] as? String, !seen.insert(id).inserted { return }
            func n(_ k: String) -> Int { max(0, (u[k] as? NSNumber)?.intValue ?? 0) }
            let t = Total(input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"),
                          cacheCreation: n("cache_creation_input_tokens"), messages: 1)
            guard t.input + t.output + t.cacheRead + t.cacheCreation > 0 else { return }   // a synthetic message
            let model = String((msg["model"] as? String ?? "desconhecido").prefix(80))
            var s = out[model] ?? Total()
            s.input += t.input; s.output += t.output; s.cacheRead += t.cacheRead; s.cacheCreation += t.cacheCreation; s.messages += 1
            out[model] = s
            if msg["model"] is String { last = model }
        }) else { return nil }
        return (out, end, last)
    }

    /// M5.4: the most of a transcript an attempt's count reads (streamed); past it, no number.
    static let attemptMaxBytes: UInt64 = 64 << 20

    /// M5.4: one attempt's agent's whole transcript as counts (all models summed; `model` the last one). nil: the path
    /// is refused (`TranscriptChunk.allowed`: not a regular `.jsonl` under `projectsDir`, a symlink, a FIFO), the file
    /// is gone or more than `maxBytes`. Never throws; never keeps a message's text.
    static func attempt(_ path: String, projectsDir: URL, maxBytes: UInt64 = attemptMaxBytes) -> TokenCount? {
        guard let url = TranscriptChunk.allowed(path, projectsDir: projectsDir),
              let r = read(url, from: 0, maxBytes: maxBytes) else { return nil }
        var t = r.byModel.values.reduce(TokenCount()) {
            $0 + TokenCount(input: $1.input, output: $1.output, cacheWrite: $1.cacheCreation, cacheRead: $1.cacheRead, messages: $1.messages)
        }
        t.model = r.last
        return t
    }
}

extension CommandRouter {
    var usageMarksFile: URL { config.paths.root.appendingPathComponent("metrics/usage-marks.json") }

    /// A Claude Stop named `transcript`: the usage written since the last read becomes `sessionUsage` events (one per model),
    /// for the terminal's session, its active work, lot and project. The file is read off the actor; one read per
    /// transcript at a time. A refused path or a failed read: nothing logged (never fails the turn).
    func recordUsage(_ tid: UUID, transcript: String) async {
        guard let me = ws.terminals.first(where: { $0.id == tid }) else { return }
        guard let url = TranscriptChunk.allowed(transcript, projectsDir: await claudeProjectsDir(me)),
              !conversations.usageReading.contains(url.path) else { return }
        conversations.usageReading.insert(url.path)
        defer { conversations.usageReading.remove(url.path) }
        let marks = usageMarksFile, mark = ConversationCapture.marks(marks)[url.path] ?? 0
        guard let r = try? await UnixSocketClient.offPool({ SessionUsage.read(url, from: mark) }), r.end != mark else { return }
        let work = try? await work.active(terminal: tid), project = await memory.repo(for: me.cwd).root?.path
        let session = url.deletingPathExtension().lastPathComponent, lot = ws.lot(of: tid)?.id
        for (model, t) in r.byModel.sorted(by: { $0.key < $1.key }) {
            memory.events.emit(MemoryEvent(type: .sessionUsage, terminal: tid, session: session, work: work?.id, lot: lot, project: project,
                                           inputTokens: t.input, outputTokens: t.output, cacheRead: t.cacheRead, cacheCreation: t.cacheCreation,
                                           model: model, messages: t.messages))
        }
        do { try ConversationCapture.setMark(marks, path: url.path, to: r.end) } catch { memoryLog("usage mark: \(error)") }
        if let m = r.last { await noteModel(tid, m) }   // the model it really ran (header, list, check, next launch)
    }

    /// M5.4: what the loop's agent `tid` used, from the transcript its own Stop hook named (nil: none seen, refused,
    /// gone, too big). Read off the actor.
    func attemptTokens(_ tid: UUID) async -> TokenCount? {
        guard let me = ws.terminals.first(where: { $0.id == tid }), let path = conversations.transcripts[tid] else { return nil }
        let projects = await claudeProjectsDir(me)
        return try? await UnixSocketClient.offPool { SessionUsage.attempt(path, projectsDir: projects) }
    }
}
