import Foundation
import CollieCore
import CollieProtocol

/// Runs the declarative usage providers in `dir` (in parallel, cached per provider). One bad provider never affects the others.
actor UsageService {
    private let dir: URL
    /// `<root>/usage`: handed to providers as COLLIE_USAGE_DIR (the dir `collie hook claude-statusline` writes into).
    private let usageDir: URL
    private var cache: [String: (report: UsageReport, at: ContinuousClock.Instant)] = [:]

    init(dir: URL) {
        self.dir = dir
        usageDir = dir.deletingLastPathComponent()
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // upgrade the pre-2J claude seed only if still byte-identical (never a user-edited file); idempotent
        let claudeFile = dir.appendingPathComponent("claude.json")
        if fm.contents(atPath: claudeFile.path) == Data(DefaultUsageProviders.claudeV1.utf8) {
            fm.createFile(atPath: claudeFile.path, contents: Data(DefaultUsageProviders.claude.utf8), attributes: [.posixPermissions: 0o600])
        }
        // once (marker beside the dir): providers the user deleted stay deleted
        let seeded = dir.deletingLastPathComponent().appendingPathComponent(".seeded")
        guard !fm.fileExists(atPath: seeded.path) else { return }
        if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true {
            for d in DefaultUsageProviders.all {
                fm.createFile(atPath: dir.appendingPathComponent("\(d.id).json").path, contents: Data(d.json.utf8),
                              attributes: [.posixPermissions: 0o600])
            }
        }
        fm.createFile(atPath: seeded.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }

    private var inflight: [String: Task<UsageReport, Never>] = [:]

    func reports(maxAge: Duration = .seconds(300)) async -> [UsageReport] {
        collectSandboxed()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        // each slot is either a ready report or a provider to fetch; everything is keyed by the provider's id (== file stem)
        var slots: [(id: String, ready: UsageReport?, provider: UsageProvider?)] = []
        let now = ContinuousClock.now
        for f in files {
            let stem = String(f.dropLast(5))
            do {
                let p = try JSONDecoder().decode(UsageProvider.self, from: Data(contentsOf: dir.appendingPathComponent(f)))
                if p.id != stem {
                    slots.append((stem, UsageReport(providerId: stem, label: stem, error: "invalid provider: id '\(p.id)' does not match file name"), nil))
                } else if !p.enabled {
                    slots.append((stem, UsageReport(providerId: p.id, label: p.label, error: "disabled"), nil))
                } else if let c = cache[p.id], now - c.at <= maxAge {
                    slots.append((stem, c.report, nil))
                } else {
                    slots.append((stem, nil, p))
                }
            } catch {
                slots.append((stem, UsageReport(providerId: stem, label: stem, error: "invalid provider: \(error.localizedDescription)"), nil))
            }
        }
        var tasks: [String: Task<UsageReport, Never>] = [:]
        for s in slots { if let p = s.provider {
            tasks[s.id] = inflight[s.id] ?? { let t = Task { await Self.fetch(p, usageDir: usageDir) }; inflight[s.id] = t; return t }()
        } }
        var out: [UsageReport] = []
        for s in slots {
            if let r = s.ready { out.append(r); continue }
            let r = await tasks[s.id]!.value
            if inflight[s.id] == tasks[s.id] { inflight[s.id] = nil }   // a later call may have started a new run
            if r.error == nil { cache[s.id] = (r, ContinuousClock.now) }   // errors are not cached: a transient failure must not stick
            out.append(r)
        }
        return out
    }

    /// A sandboxed terminal can't write `<root>/usage` (Collie data): its statusline hook writes into its own
    /// `<root>/sandbox/<id>/state/usage`. The newest of those (a regular file, JSON, small) is copied here first.
    func collectSandboxed() {
        let fm = FileManager.default, name = ClaudeRateLimits.fileName
        let sandbox = usageDir.deletingLastPathComponent().appendingPathComponent("sandbox")
        func regular(_ p: String) -> Date? {
            guard let a = try? fm.attributesOfItem(atPath: p), a[.type] as? FileAttributeType == .typeRegular else { return nil }
            return a[.modificationDate] as? Date
        }
        let newest = ((try? fm.contentsOfDirectory(atPath: sandbox.path)) ?? [])
            .map { sandbox.appendingPathComponent("\($0)/state/usage/\(name)").path }
            .compactMap { p in regular(p).map { (p, $0) } }.max { $0.1 < $1.1 }
        guard let (p, t) = newest, t > (regular(usageDir.appendingPathComponent(name).path) ?? .distantPast),
              let d = Self.readSmallRegular(p), (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else { return }
        try? ClaudeRateLimits.write(d, to: usageDir)   // ponytail: an agent can still fake its own numbers (R16, accepted)
    }

    /// M1: the agent can swap the file between the check and the read: one fd, never a link, never blocking (a FIFO),
    /// regular by fstat, at most 64 KiB.
    static func readSmallRegular(_ path: String, cap: Int = 64 << 10) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size < cap else { return nil }
        var buf = [UInt8](repeating: 0, count: cap)
        let n = read(fd, &buf, cap)
        return n >= 0 && n < cap ? Data(buf[0..<n]) : nil
    }

    private static func fetch(_ p: UsageProvider, usageDir: URL) async -> UsageReport {
        func fail(_ m: String) -> UsageReport { UsageReport(providerId: p.id, label: p.label, error: m) }
        guard let cmd = p.command.first, !cmd.isEmpty else { return fail("invalid provider: empty command") }
        let env = ProcessInfo.processInfo.environment
        let path = [env["PATH"], "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }.joined(separator: ":")
        guard let exe = resolve(cmd, path: path) else { return fail("command not found: \(cmd)") }
        var penv = ["PATH": path]
        for k in ["HOME", "USER", "LANG"] { if let v = env[k] { penv[k] = v } }
        penv["COLLIE_USAGE_DIR"] = usageDir.path
        let secs = min(max(p.timeoutSeconds ?? 30, 0.1), 120)
        let res: ProcessResult
        do {
            res = try await BoundedProcess.run(executable: exe, args: Array(p.command.dropFirst()),
                                               in: FileManager.default.homeDirectoryForCurrentUser, env: penv, timeout: .seconds(secs))
        } catch let e where e.code == .timeout { return fail("timeout after \(secs)s")
        } catch { return fail(error.message) }
        if res.truncated { return fail("output exceeds 1 MiB") }
        if res.status != 0 { return fail("exit \(res.status): \(res.stderr.prefix(200))") }
        let text: String
        switch p.parse {
        case .json: text = res.stdout
        case .jsonlLast(let needle):
            guard let l = res.stdout.split(whereSeparator: \.isNewline).last(where: { $0.contains(needle) }) else {
                return fail("no output line contains '\(needle)'")
            }
            text = String(l)
        }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return fail("unreadable JSON output") }
        let ws = p.windows.map { w in
            WindowValue(label: w.label, usedPercent: JSONPointer.eval(w.usedPercent, in: root).flatMap(number),
                        resetsAt: w.resetsAt.flatMap { JSONPointer.eval($0, in: root) }.flatMap(date))
        }
        // a bare `{}` is "nothing recorded yet" (the claude provider before any statusLine refresh): "—" windows, not an error
        if ws.allSatisfy({ $0.usedPercent == nil && $0.resetsAt == nil }), root != .object([:]) { return fail("no usage fields found") }
        return UsageReport(providerId: p.id, label: p.label, windows: ws)
    }

    private static func resolve(_ cmd: String, path: String) -> URL? {
        let fm = FileManager.default
        if cmd.contains("/") { return fm.isExecutableFile(atPath: cmd) ? URL(fileURLWithPath: cmd) : nil }
        return path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(cmd) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    private static func number(_ v: JSONValue) -> Double? {
        switch v { case .number(let n): n; case .string(let s): Double(s); default: nil }
    }
    /// Epoch seconds (milliseconds when absurdly large) or ISO-8601 (with or without fractional seconds).
    private static func date(_ v: JSONValue) -> Date? {
        if let n = number(v) { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        guard case .string(let s) = v else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: s)
    }
}
