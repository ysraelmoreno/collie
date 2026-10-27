import Foundation

/// The new part of a Claude conversation transcript, as plain text for the curator. The path is agent-controlled (a hook
/// payload), so it is trusted only as a regular `.jsonl` file — not a symlink — whose real path is under `<config>/projects/`;
/// the content is untrusted data: only user and assistant text is kept (no tool inputs or outputs, no thinking, no system
/// reminders or meta entries, pasted bodies cut to 500 characters), every block scrubbed of secrets.
enum TranscriptChunk {
    static let pastedMax = 500
    /// Read block size; a single line longer than this grows the buffer. ponytail: one huge tool_result line is held whole.
    private static let block = 1 << 20

    /// `path`'s real URL when it may be read, else nil.
    static func allowed(_ path: String, projectsDir: URL) -> URL? {
        guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }   // no symlink as the last component
        guard let real = realpath(path, nil), let base = realpath(projectsDir.path, nil) else { return nil }
        defer { free(real); free(base) }
        let r = String(cString: real), b = String(cString: base)
        guard r.hasPrefix(b + "/"), r.hasSuffix(".jsonl") else { return nil }   // a symlinked dir leading out lands elsewhere
        return URL(fileURLWithPath: r)
    }

    /// The messages in the complete lines after `offset` (from 0 when the file is shorter: it was rewritten), the newest
    /// `maxScalars` of them; `userMessages` counts the user's text messages of the whole chunk; `end`: the byte after its
    /// last complete line (a partial last line is the next chunk's). nil: cannot be opened as a regular file.
    static func read(_ url: URL, from offset: UInt64, secrets: Set<String>, maxScalars: Int) -> (text: String, userMessages: Int, end: UInt64)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let start = UInt64(st.st_size) < offset ? 0 : offset
        guard (try? h.seek(toOffset: start)) != nil else { return nil }
        var blocks: [String] = [], kept = 0, users = 0, end = start, buf = Data()
        while let data = try? h.read(upToCount: block), !data.isEmpty {
            buf.append(data)
            guard let nl = buf.lastIndex(of: 10) else { continue }
            for raw in buf[buf.startIndex...nl].split(separator: 10) {
                guard let (isUser, text) = message(Data(raw)) else { continue }
                if isUser { users += 1 }
                let b = (isUser ? "Usuário: " : "Agente: ") + LotBoards.scrub(text, secrets: secrets)
                blocks.append(b); kept += b.unicodeScalars.count + 2
                while kept > 2 * maxScalars, blocks.count > 1 { kept -= blocks.removeFirst().unicodeScalars.count + 2 }
            }
            end += UInt64(buf.distance(from: buf.startIndex, to: nl) + 1)
            buf = Data(buf[buf.index(after: nl)...])
        }
        let all = blocks.joined(separator: "\n\n")
        return (String(String.UnicodeScalarView(all.unicodeScalars.suffix(maxScalars))), users, end)
    }

    /// (from the user, its text) for a user or assistant text message; nil for anything else or a malformed line.
    private static func message(_ line: Data) -> (Bool, String)? {
        guard let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              e["isMeta"] as? Bool != true, e["isSidechain"] as? Bool != true,
              let msg = e["message"] as? [String: Any] else { return nil }
        let type = e["type"] as? String
        guard type == "user" || type == "assistant", msg["role"] as? String == type else { return nil }
        let raw: String
        if let s = msg["content"] as? String { raw = s }
        else if let items = msg["content"] as? [[String: Any]] {
            raw = items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else { return nil }
        let text = clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (type == "user", text)
    }

    private static func clean(_ s: String) -> String {
        s.replacing(/(?s)<(system-reminder|local-command-stdout|local-command-stderr)>.*?<\/\1>/, with: "")
            .replacing(/(?s)<pasted_content([^>]*)>(.*?)<\/pasted_content>/) { m in
                let body = String(m.output.2)
                return "<pasted_content\(m.output.1)>\(body.count > pastedMax ? String(body.prefix(pastedMax)) + "…" : body)</pasted_content>"
            }
    }
}
