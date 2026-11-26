import Foundation
import CollieCore

/// The files a task declared as its evidence (`work task add --evidence <glob>`), copied out of the worktree when the
/// loop approves the task. Only reads inside the worktree, so never more than the task's check could read.
enum EvidenceFiles {
    static let extensions: Set<String> = ["png", "gif", "jpg", "mp4", "txt", "md"]
    static let maxBytes = 20 * 1024 * 1024

    struct Copied: Sendable, Equatable {
        /// The names copied (flat, in the glob's sorted order) and the folder they are in.
        var files: [String] = []; var dir: String
        /// What the owner should know (the ceiling was hit); nil: nothing.
        var note: String?
    }

    /// Why `glob` is not accepted (in English, for the agent); nil: it is. Relative to the worktree, no `..`.
    static func refusal(_ glob: String) -> String? {
        if glob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "is empty" }
        if glob.hasPrefix("/") || glob.hasPrefix("~") { return "must be relative to the paddock's worktree" }
        if glob.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return "may not hold '..'" }
        if glob.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "may not hold control characters" }
        return nil
    }

    /// `<base>/evidence/<task>/`, `base` being the loop's folder of the work (`<root>/work-loops/<work>/`).
    // ponytail: a task id is the agent's text, so anything but [A-Za-z0-9_-] becomes "_"; two ids that differ only
    // there share a folder (the later approval replaces the earlier files). Hash the id if that ever happens.
    static func dir(_ base: URL, task: String) -> URL {
        let safe = String(task.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return base.appendingPathComponent("evidence").appendingPathComponent(safe.isEmpty ? "_" : safe)
    }

    /// Copies what `glob` matches in `worktree` into `dest` (emptied first; folder 0700, files 0600). A match counts
    /// only when, symlinks resolved, it is a regular file with one link inside the worktree (not under `.git`) with one
    /// of `extensions`; anything else is ignored. The file that would pass `maxBytes` in total stops the copy, with a note.
    static func copy(_ glob: String, from worktree: URL, to dest: URL, maxBytes: Int = maxBytes) -> Copied {
        var out = Copied(dir: dest.path)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard refusal(glob) == nil else { return out }
        let root = SignedAppCheck.realPath(worktree)
        // the worktree's own path is literal: its glob characters are escaped
        let literal = root.map { "*?[]{}\\".contains($0) ? "\\\($0)" : String($0) }.joined()
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(literal + "/" + glob, GLOB_BRACE, nil, &g) == 0, let found = g.gl_pathv else { return out }
        var total = 0
        for i in 0..<Int(g.gl_pathc) {
            guard let c = found[i] else { continue }
            let real = SignedAppCheck.realPath(URL(fileURLWithPath: String(cString: c)))
            let name = (real as NSString).lastPathComponent
            guard real.hasPrefix(root + "/"), !real.dropFirst(root.count).split(separator: "/").contains(".git"),
                  extensions.contains((name as NSString).pathExtension.lowercased()),
                  !out.files.contains(name) else { continue }   // ponytail: flat names, the first of two equal ones wins
            let fd = open(real, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { continue }
            // one byte past what is left: a file that grew since the stat still stops here
            let left = maxBytes - total
            guard Int(st.st_size) <= left, let data = try? file.read(upToCount: left + 1), data.count <= left else {
                out.note = tr("os arquivos passaram de \(maxBytes / 1_048_576) MB no total: a cópia parou em «\(name)» (\(out.files.count) copiados)",
                         "the files exceeded \(maxBytes / 1_048_576) MB in total: the copy stopped at «\(name)» (\(out.files.count) copied)")
                break
            }
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: dest.appendingPathComponent(name).path, contents: data, attributes: [.posixPermissions: 0o600]) else { continue }
            total += data.count; out.files.append(name)
        }
        return out
    }
}
