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
    static func read(_ url: URL, from offset: UInt64) -> (byModel: [String: Total], end: UInt64)? {
        var seen = Set<String>(), out: [String: Total] = [:]
        guard let end = TranscriptChunk.lines(url, from: offset, { raw in
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
        }) else { return nil }
        return (out, end)
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
    }
}
