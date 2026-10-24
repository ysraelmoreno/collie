import Foundation
import CollieCore
import CollieProtocol

/// The review files a project already has, read by the daemon (never by the curator beyond the fenced findings).
enum ReviewIngest {
    /// What `files` matches (documentation; the walk below is the matcher).
    static let globs = [".superpowers/sdd/**/*review*.md", ".superpowers/sdd/**/*-report.md"]
    static let excerptMax = 8_000, readMax = 1 << 20, perRun = 20, depthMax = 8
    /// A finding's heading or bullet names one of these (word start, any case).
    static let keywords = #"(^|[^\p{L}\p{N}])(critical|important|minor|blocker|crítico|importante|must fix|bug|race|symlink)"#

    /// Under `<repo>/.superpowers/sdd`, never through a symlink (a linked folder or file is skipped, as is a linked
    /// `.superpowers` or `sdd`). Sorted by path.
    static func files(in repo: URL) -> [URL] {
        func kind(_ u: URL) -> mode_t? {
            var st = stat()
            return lstat(u.path, &st) == 0 ? st.st_mode & S_IFMT : nil
        }
        let sdd = repo.appendingPathComponent(".superpowers/sdd")
        guard kind(sdd.deletingLastPathComponent()) == S_IFDIR, kind(sdd) == S_IFDIR else { return [] }
        var out: [URL] = []
        func walk(_ d: URL, _ depth: Int) {
            guard depth < depthMax, let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return }
            for n in names.sorted() {
                let u = d.appendingPathComponent(n)
                switch kind(u) {
                case S_IFDIR: walk(u, depth + 1)
                case S_IFREG: if n.hasSuffix(".md"), n.contains("review") || n.hasSuffix("-report.md") { out.append(u) }
                default: continue   // a symlink is never followed
                }
            }
        }
        walk(sdd, 0)
        return out
    }

    /// `O_NOFOLLOW` (a file swapped for a link after the walk is refused), a regular file only, ≤ 1 MiB read.
    static func read(_ u: URL) -> (text: String, mtime: Date, size: Int)? {
        let fd = open(u.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data(count: min(Int(st.st_size), readMax))
        let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n >= 0 else { return nil }
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        return (String(decoding: data.prefix(n), as: UTF8.self), mtime, Int(st.st_size))
    }

    /// The finding lines: everything under a heading that names a keyword (to the next heading), and a bullet that names
    /// one plus its next line; in order, whole lines, ≤ `max` unicode scalars. "" when there is none.
    static func findings(_ text: String, max: Int) -> String {
        func hit(_ s: String) -> Bool { s.range(of: keywords, options: [.regularExpression, .caseInsensitive]) != nil }
        let lines = text.components(separatedBy: "\n")
        var keep = IndexSet(), under = false
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { under = hit(t); if under { keep.insert(i) }; continue }
            if under { if !t.isEmpty { keep.insert(i) }; continue }
            let bullet = ["- ", "* ", "+ ", "**"].contains { t.hasPrefix($0) } || t.first?.isNumber == true && t.contains(". ")
            if bullet, hit(t) { keep.insert(i); if i + 1 < lines.count { keep.insert(i + 1) } }
        }
        var out = "", used = 0
        for i in keep {
            let l = lines[i], cost = l.unicodeScalars.count + (out.isEmpty ? 0 : 1)
            guard used + cost <= max else { break }
            out += (out.isEmpty ? "" : "\n") + l; used += cost
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which review files were already ingested: `<root>/learning/reviews.json` (0600), real path → mtime and size.
struct ReviewSeen {
    private struct Entry: Codable { var mtime: Double; var size: Int }
    let file: URL
    init(file: URL) { self.file = file }

    private func load() -> [String: Entry] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }
    private static func key(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

    func isNew(_ u: URL, mtime: Date, size: Int) -> Bool {
        guard let e = load()[Self.key(u)] else { return true }
        return e.size != size || abs(e.mtime - mtime.timeIntervalSince1970) > 0.001
    }

    func mark(_ u: URL, mtime: Date, size: Int) throws {
        var all = load()
        all[Self.key(u)] = Entry(mtime: mtime.timeIntervalSince1970, size: size)
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".reviews-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(all), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

extension CommandRouter {
    var reviewSeen: ReviewSeen { ReviewSeen(file: config.paths.root.appendingPathComponent("learning/reviews.json")) }

    /// The repo's new or changed review files (≤ 20 a run) become `pitfall` jobs over their findings (scrubbed, fenced by
    /// the job), scoped to the project's store. A file with no findings costs no job; each is marked seen once handled.
    func ingestReviews(repo: RepoMemory) async {
        guard let root = repo.root, repo.lotId == nil else { return }
        let seen = reviewSeen
        // read off the actor, on the store's queue
        typealias Fresh = (url: URL, text: String, mtime: Date, size: Int)
        let fresh = (try? await repo.run { _ -> [Fresh] in
            var out: [Fresh] = []
            for u in ReviewIngest.files(in: root) where out.count < ReviewIngest.perRun {
                if let f = ReviewIngest.read(u), seen.isNew(u, mtime: f.mtime, size: f.size) { out.append((u, f.text, f.mtime, f.size)) }
            }
            return out
        }) ?? []
        guard !fresh.isEmpty else { return }
        let secrets = await auth.secrets()
        let classes = PitfallClasses.summaries(await PitfallClasses.active(repo))
        for f in fresh {
            let excerpt = ReviewIngest.findings(LotBoards.scrub(f.text, secrets: secrets), max: ReviewIngest.excerptMax)
            let rel = f.url.path.hasPrefix(root.path + "/") ? String(f.url.path.dropFirst(root.path.count + 1)) : f.url.lastPathComponent
            if !excerpt.isEmpty {
                let p = PitfallPayload(family: repo.key, scope: .project, instance: nil, review: .init(file: rel, excerpt: excerpt), classes: classes)
                guard let payload = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p)),
                      await curator.enqueue(CuratorJob(id: UUID(), kind: .pitfall, store: repo.key, payload: payload,
                                                       dedupe: "review|\(repo.key)|\(rel)|\(f.size)|\(f.mtime.timeIntervalSince1970)",
                                                       createdAt: Date(), attempts: 0)) else { continue }   // full: tried next run
            }
            do { try seen.mark(f.url, mtime: f.mtime, size: f.size) } catch { memoryLog("reviews seen: \(error)") }
        }
    }
}
