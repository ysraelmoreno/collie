import Foundation
import CollieCore
import CollieProtocol

/// The review files a project already has, read by the daemon (never by the curator beyond the fenced findings).
enum ReviewIngest {
    /// What `files` matches (documentation; the walk below is the matcher).
    static let globs = [".superpowers/sdd/**/*review*.md", ".superpowers/sdd/**/*-report.md"]
    static let excerptMax = 8_000, readMax = 1 << 20, perRun = 20, depthMax = 8
    /// R8: review jobs a run (a work close, a daily consolidation) and a project a day. R9: files a walk keeps.
    static let jobsPerRun = 1, jobsPerDay = 5, filesMax = 200
    /// A finding's heading or bullet names one of these (word start, any case).
    static let keywords = #"(^|[^\p{L}\p{N}])(critical|important|minor|blocker|crítico|importante|must fix|bug|race|symlink)"#

    /// Under `<repo>/.superpowers/sdd`, never through a symlink: every folder is opened with `O_NOFOLLOW|O_DIRECTORY` from
    /// its parent's descriptor (a folder swapped for a link mid-walk is refused), entries checked with `fstatat` no-follow.
    /// Sorted per folder; at most 200 files.
    static func files(in repo: URL) -> [URL] {
        func sub(_ fd: Int32, _ name: String) -> Int32 { openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        let top = open(repo.path, O_RDONLY | O_DIRECTORY)
        guard top >= 0 else { return [] }
        let sp = sub(top, ".superpowers"); close(top)
        guard sp >= 0 else { return [] }
        let sdd = sub(sp, "sdd"); close(sp)
        guard sdd >= 0 else { return [] }
        var out: [URL] = []
        /// Takes `fd` (closed here).
        func walk(_ fd: Int32, _ at: URL, _ depth: Int) {
            guard let dir = fdopendir(fd) else { close(fd); return }
            defer { closedir(dir) }
            var names: [String] = []
            while let e = readdir(dir) {
                let n = withUnsafePointer(to: &e.pointee.d_name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
                if n != ".", n != ".." { names.append(n) }
            }
            for n in names.sorted() where out.count < filesMax {
                var st = stat()
                guard fstatat(fd, n, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: if depth + 1 < depthMax { let c = sub(fd, n); if c >= 0 { walk(c, at.appendingPathComponent(n), depth + 1) } }
                case S_IFREG: if n.hasSuffix(".md"), n.contains("review") || n.hasSuffix("-report.md") { out.append(at.appendingPathComponent(n)) }
                default: continue   // a symlink is never followed
                }
            }
        }
        walk(sdd, repo.appendingPathComponent(".superpowers/sdd"), 0)
        return out
    }

    /// `O_NOFOLLOW`, a regular file only, and (R9) the file actually opened lies inside `within` (its real path, from the
    /// descriptor: a folder swapped for a link after the walk is caught); ≤ 1 MiB read.
    static func read(_ u: URL, within: URL) -> (text: String, mtime: Date, size: Int)? {
        let fd = open(u.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0, let base = realpath(within.path, nil) else { return nil }
        let inside = String(cString: buf).hasPrefix(String(cString: base) + "/")
        free(base)
        var st = stat()
        guard inside, fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
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

/// Which review files were already ingested (real path → mtime and size) and the review jobs each project spent today:
/// `<root>/learning/reviews.json` (0600). Only the router uses it.
struct ReviewSeen {
    private struct Entry: Codable { var mtime: Double; var size: Int }
    private struct Spent: Codable { var day: String; var jobs: Int }
    private struct State: Codable { var files: [String: Entry] = [:]; var spent: [String: Spent] = [:] }
    let file: URL
    init(file: URL) { self.file = file }

    private func load() -> State {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
    private static func key(_ u: URL) -> String { u.resolvingSymlinksInPath().path }
    static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func isNew(_ u: URL, mtime: Date, size: Int) -> Bool {
        guard let e = load().files[Self.key(u)] else { return true }
        return e.size != size || abs(e.mtime - mtime.timeIntervalSince1970) > 0.001
    }

    func mark(_ u: URL, mtime: Date, size: Int) throws {
        var s = load()
        s.files[Self.key(u)] = Entry(mtime: mtime.timeIntervalSince1970, size: size)
        try save(s)
    }

    /// Review jobs `project` queued today.
    func spent(_ project: String) -> Int { load().spent[project].flatMap { $0.day == Self.today() ? $0.jobs : nil } ?? 0 }

    func spend(_ project: String) throws {
        var s = load()
        s.spent[project] = Spent(day: Self.today(), jobs: spent(project) + 1)
        try save(s)
    }

    private func save(_ s: State) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".reviews-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(s), attributes: [.posixPermissions: 0o600]) else {
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

    /// The repo's new or changed review files (≤ 20 read a run) become `pitfall` jobs over their findings (scrubbed,
    /// fenced by the job), scoped to the project's store: R8 at most 1 a run and 5 a project a day (the rest wait, unmarked).
    /// A file with no findings costs no job; each is marked seen once handled.
    func ingestReviews(repo: RepoMemory) async {
        guard let root = repo.root, repo.lotId == nil else { return }
        let seen = reviewSeen
        var left = min(ReviewIngest.jobsPerRun, ReviewIngest.jobsPerDay - seen.spent(repo.key))
        // read off the actor, on the store's queue
        typealias Fresh = (url: URL, text: String, mtime: Date, size: Int)
        let sdd = root.appendingPathComponent(".superpowers/sdd")
        let fresh = (try? await repo.run { _ -> [Fresh] in
            var out: [Fresh] = []
            for u in ReviewIngest.files(in: root) where out.count < ReviewIngest.perRun {
                if let f = ReviewIngest.read(u, within: sdd), seen.isNew(u, mtime: f.mtime, size: f.size) { out.append((u, f.text, f.mtime, f.size)) }
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
                guard left > 0 else { continue }   // over budget: seen on a later run
                let p = PitfallPayload(family: repo.key, scope: .project, instance: nil, review: .init(file: rel, excerpt: excerpt), classes: classes)
                guard let payload = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p)),
                      await curator.enqueue(CuratorJob(id: UUID(), kind: .pitfall, store: repo.key, payload: payload,
                                                       dedupe: "review|\(repo.key)|\(rel)|\(f.size)|\(f.mtime.timeIntervalSince1970)",
                                                       createdAt: Date(), attempts: 0)) else { continue }   // full: tried next run
                left -= 1
                do { try seen.spend(repo.key) } catch { memoryLog("reviews spent: \(error)") }
            }
            do { try seen.mark(f.url, mtime: f.mtime, size: f.size) } catch { memoryLog("reviews seen: \(error)") }
        }
    }
}
