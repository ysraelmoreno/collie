import Foundation
import CollieDevice
import CollieProtocol
import CryptoKit

/// Runs `executable args` in `dir`; throws unless it exits 0. The daemon's is `AndroidInstaller.run` (`BoundedProcess`:
/// own process group, stdin /dev/null, killed past the timeout).
typealias AndroidRunner = @Sendable (_ executable: String, _ args: [String], _ dir: URL) async throws -> Void

/// Installs the Android SDK pieces Collie downloads itself. Phase 1, `prepare`: Collie's JDK (only when no usable Java)
/// and `cmdline-tools` (only when no usable one), downloaded and extracted in `<sdk>/.collie-staging/prepare/`, moved into
/// place only once checksummed and extracted. The staging is removed on success and failure; nothing outside it is
/// deleted or overwritten. Phase 2 (`install`, below): licenses, then `sdkmanager` installs the rest.
actor AndroidInstaller {
    /// The daemon's root. ponytail: unused; job state is in memory only (spec).
    let root: URL
    let env: [String: String], home: String
    let fetch: AndroidFetch, runner: AndroidRunner
    let isAppleSilicon: Bool, javaCandidates: [String]?
    /// Bytes free on the volume holding a path (`nil`: unknown, not checked).
    let freeSpace: @Sendable (String) -> Int64?
    /// Where `sdkmanager`'s pidfile goes (`OrphanReaper`), so a restarted daemon kills a group a crash left behind:
    /// must be the daemon's `config.paths.runDir` (the only dir it reaps).
    let runDir: URL
    /// Names another `sdkmanager` or Android Studio when one runs (`nil`: none): the install is then `busy`.
    let othersRunning: @Sendable (_ studioBlocks: Bool) async -> String?

    // Phase 2 job state, in memory only: a daemon restart forgets it, so `busy` never outlives the process.
    var job: AndroidStatus.Job?
    var running = false
    var work: Task<Void, Error>?
    var process: LongProcess?
    /// `cancel` arrived while `begin` was still checking for other `sdkmanager`s (no job Task yet).
    var cancelRequested = false
    /// What the last `sdkmanager --licenses` printed (`nil`: not asked yet).
    var known: [(id: String, title: String, text: String)]?

    init(root: URL, env: [String: String], home: String, runDir: URL, fetch: @escaping AndroidFetch = AndroidDownload.fetch,
         runner: @escaping AndroidRunner = AndroidInstaller.run, isAppleSilicon: Bool = AndroidInstaller.appleSilicon,
         javaCandidates: [String]? = nil, freeSpace: @escaping @Sendable (String) -> Int64? = AndroidInstaller.free,
         othersRunning: @escaping @Sendable (_ studioBlocks: Bool) async -> String? = AndroidInstaller.others) {
        self.root = root; self.env = env; self.home = home; self.fetch = fetch; self.runner = runner
        self.isAppleSilicon = isAppleSilicon; self.javaCandidates = javaCandidates; self.freeSpace = freeSpace
        self.runDir = runDir; self.othersRunning = othersRunning
        // an orphan of a daemon that died mid-job (no job survives a restart)
        try? FileManager.default.removeItem(atPath: AndroidSdk.root(env: env, home: home) + "/.collie-staging")
    }

    /// Phase 1. A no-op (no download, no staging) when Java and `cmdline-tools` are both usable already.
    /// `progress(item, bytes, total)` per download chunk; item is `java` or `cmdline-tools`.
    func prepare(progress: @escaping @Sendable (_ item: String, _ bytes: Int64, _ total: Int64) -> Void = { _, _, _ in })
        async throws(ProtocolError) {
        guard isAppleSilicon else {
            throw ProtocolError(code: .unavailable, message: "Android setup supports only Apple Silicon Macs (arm64).")
        }
        let fm = FileManager.default
        let sdk = AndroidSdk.root(env: env, home: home)
        let needTools = AndroidSdk.sdkmanager(in: sdk, exists: { fm.isExecutableFile(atPath: $0) }) == nil
        let needJava = AvdManager.javaHome(env: env, home: home, javaCandidates: javaCandidates) == nil
        guard needTools || needJava else { return }

        let staging = URL(fileURLWithPath: sdk).appendingPathComponent(".collie-staging/prepare")
        try? fm.removeItem(at: staging)   // an orphan of a crashed run
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) }
        catch { throw ProtocolError(code: .unavailable, message: "cannot create \(staging.path): \(error.localizedDescription)") }
        defer {
            try? fm.removeItem(at: staging)
            rmdir(staging.deletingLastPathComponent().path)   // `.collie-staging` too, only if empty
        }
        do {
            let tools = needTools ? try await resolve(AndroidDownload.catalog, staging, "catalog.xml", AndroidDownload.cmdlineTools) : nil
            let jdk = needJava ? try await resolve(AndroidDownload.temurinAPI, staging, "temurin.json", AndroidDownload.temurin) : nil
            let total = (tools?.size ?? 0) + (jdk?.size ?? 0)
            if let free = freeSpace(staging.path), free < 2 * total {
                throw ProtocolError(code: .unavailable, message: "not enough disk space: \(2 * total) bytes needed next to the SDK, \(free) free")
            }
            if let jdk {
                let dest = URL(fileURLWithPath: AvdManager.collieJdk(home)).deletingLastPathComponent().deletingLastPathComponent()
                let file = try await download(jdk, staging.appendingPathComponent("jdk.tar.gz"), "java", progress)
                let out = staging.appendingPathComponent("jdk")
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                try await runner("/usr/bin/tar", ["-xzf", file.path, "--strip-components=1", "-C", out.path], staging)
                try place(out, at: dest, check: "Contents/Home/bin/java")
            }
            if let tools {
                let file = try await download(tools, staging.appendingPathComponent("cmdline-tools.zip"), "cmdline-tools", progress)
                let out = staging.appendingPathComponent("unzip")
                try await runner("/usr/bin/ditto", ["-x", "-k", file.path, out.path], staging)
                try place(out.appendingPathComponent("cmdline-tools"), at: URL(fileURLWithPath: sdk).appendingPathComponent("cmdline-tools/latest"),
                          check: "bin/sdkmanager")
            }
        } catch let e as ProtocolError {
            throw e
        } catch where error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw Self.cancelled
        } catch {
            throw ProtocolError(code: .unavailable, message: error.localizedDescription)
        }
    }

    /// What `prepare` throws when its task is cancelled (compare with `==`).
    static let cancelled = ProtocolError(code: .internal, message: "Android setup cancelled")
    /// The catalog / API answer is a few MB at most.
    static let indexCap = 16 << 20

    /// Fetches a small index (catalog / API answer) into the staging and parses it.
    private func resolve(_ url: URL, _ staging: URL, _ name: String,
                         _ parse: (Data) throws(ProtocolError) -> AndroidDownload.Archive) async throws -> AndroidDownload.Archive {
        let f = staging.appendingPathComponent(name)
        try await fetch(url, f, { _, _ in })
        let size = (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        guard size <= Self.indexCap else { throw ProtocolError(code: .unavailable, message: "\(url.host ?? "") answered more than 16 MiB") }
        return try parse(try Data(contentsOf: f))
    }

    private func download(_ a: AndroidDownload.Archive, _ to: URL, _ item: String,
                          _ progress: @escaping @Sendable (String, Int64, Int64) -> Void) async throws -> URL {
        guard AndroidDownload.allowed(a.url) else {
            throw ProtocolError(code: .unavailable, message: "download host not allowed: \(a.url.absoluteString)")
        }
        try await fetch(a.url, to, { progress(item, $0, $1) })
        try AndroidDownload.verify(to, checksum: a.checksum, type: a.type)
        return to
    }

    /// Moves the extracted `src` to `dest` once `src/check` is executable and no symlink in it points outside it.
    /// Never replaces an existing `dest`.
    private func place(_ src: URL, at dest: URL, check: String) throws {
        let fm = FileManager.default
        for rel in fm.enumerator(atPath: src.path)?.compactMap({ $0 as? String }) ?? [] {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: src.appendingPathComponent(rel).path) else { continue }
            guard Self.staysInside(link: rel, target: target) else {
                throw ProtocolError(code: .unavailable, message: "the downloaded archive has a link out of it: \(rel) -> \(target)")
            }
        }
        guard fm.isExecutableFile(atPath: src.appendingPathComponent(check).path) else {
            throw ProtocolError(code: .unavailable, message: "the downloaded archive has no \(check)")
        }
        guard !fm.fileExists(atPath: dest.path) else {
            throw ProtocolError(code: .conflict, message: "\(dest.path) exists but is not usable; remove it and try again")
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: src, to: dest)
    }

    /// Lexically: does `target` (a symlink at `link`, both relative to the archive root) stay in the root? Absolute: no.
    static func staysInside(link: String, target: String) -> Bool {
        guard !target.hasPrefix("/") else { return false }
        var stack = link.split(separator: "/").dropLast().map(String.init)
        for c in target.split(separator: "/") where c != "." {
            if c == ".." { guard !stack.isEmpty else { return false }; stack.removeLast() } else { stack.append(String(c)) }
        }
        return true
    }

    static let run: AndroidRunner = { exe, args, dir in
        let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: exe), args: args, in: dir,
                                             env: ["PATH": "/usr/bin:/bin"], timeout: .seconds(600), cap: 64 << 10)
        guard r.status == 0 else {
            throw ProtocolError(code: .unavailable, message: "\((exe as NSString).lastPathComponent) failed: \(r.stderr.prefix(500))")
        }
    }

    /// `hw.optional.arm64` is 1 on Apple Silicon, also for a process running under Rosetta.
    static let appleSilicon: Bool = {
        var v: Int32 = 0; var n = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &n, nil, 0) == 0 && v == 1
    }()

    static let free: @Sendable (String) -> Int64? = { path in
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// What `android.status` returns. `needs`: `needsPrepare` (no Java or no `cmdline-tools`), `needsLicense` (licenses
/// pending, or not read yet), `ready` (nothing blocks `install`: everything is there, or the rest needs no new license).
struct AndroidStatus: Codable, Sendable, Equatable {
    struct Sdk: Codable, Sendable, Equatable { var path: String; var source: String }
    /// `state`: ok | missing | installing; `detail`: where it is (empty when missing).
    struct Item: Codable, Sendable, Equatable { var id: String; var state: String; var detail: String }
    /// `phase`: prepare | install | done | failed | cancelled. Kept after the end, so a failure stays visible.
    struct Job: Codable, Sendable, Equatable {
        var phase: String
        var item: String? = nil, percent: Int? = nil, bytes: Int64? = nil, total: Int64? = nil, error: String? = nil
    }
    var sdk: Sdk; var items: [Item]; var needs: String; var job: Job?; var lite: Bool
}

/// Phase 2: licenses and the `sdkmanager` packages, as one in-memory job.
extension AndroidInstaller {
    struct License: Codable, Sendable, Equatable { var id: String; var title: String; var text: String; var accepted: Bool }

    /// sdkmanager gives no sizes up front: fixed estimates (download + unzip) for the 2x free-space check.
    static let estimates: [String: Int64] = ["platform-tools": 15 << 20, "emulator": 400 << 20, "image": 6 << 30]
    static let notReady = ProtocolError(code: .unavailable,
                                        message: "notReady: Java and cmdline-tools are not installed yet; run the install (prepare) first")

    private var sdk: (path: String, source: String) {
        AndroidSdk.resolve(env: env, home: home, colliePath: "\(home)/Library/Application Support/Collie/android-sdk",
                           exists: { FileManager.default.fileExists(atPath: $0) })
    }
    private var java: String? { AvdManager.javaHome(env: env, home: home, javaCandidates: javaCandidates) }
    private func sdkmanagerPath(_ sdk: String) -> String? {
        AndroidSdk.sdkmanager(in: sdk, exists: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// The spec's items in install order, with where each is (`nil`: missing).
    private func items(_ sdk: String) -> [(id: String, at: String?)] {
        func exe(_ rel: String) -> String? { FileManager.default.isExecutableFile(atPath: "\(sdk)/\(rel)") ? "\(sdk)/\(rel)" : nil }
        let image = LiteAvd.installedImages(sdkRoot: URL(fileURLWithPath: sdk))
            .first { $0.split(separator: ";").dropFirst(2).first?.hasPrefix("google_apis") == true }
        return [("java", java), ("cmdline-tools", sdkmanagerPath(sdk)), ("platform-tools", exe("platform-tools/adb")),
                ("emulator", exe("emulator/emulator")), ("image", image)]
    }

    func status() -> AndroidStatus {
        let sdk = sdk, found = items(sdk.path)
        let prepared = found.prefix(2).allSatisfy { $0.at != nil }
        let noPending = known.map { withAccepted(sdk.path, $0).allSatisfy(\.accepted) } ?? false
        let needs = !prepared ? "needsPrepare" : found.allSatisfy({ $0.at != nil }) || noPending ? "ready" : "needsLicense"
        let lite = (env["ANDROID_AVD_HOME"] ?? "\(home)/.android/avd") + "/\(LiteAvd.name).avd/config.ini"
        return AndroidStatus(
            sdk: .init(path: sdk.path, source: sdk.source),
            items: found.map { .init(id: $0.id, state: $0.at != nil ? "ok" : running && job?.item == $0.id ? "installing" : "missing",
                                     detail: $0.at ?? "") },
            needs: needs, job: job, lite: FileManager.default.fileExists(atPath: lite))
    }

    /// The licenses `sdkmanager --licenses` prints (the ones it considers not accepted), `accepted` read from
    /// `<sdk>/licenses/<id>`. Refreshes what `status` knows. During a job (or another read): what was last read, else
    /// `busy` (never a second `sdkmanager`). The read itself holds `running`, so no job starts next to it.
    func licenses() async throws(ProtocolError) -> [License] {
        guard !running else {
            guard let known else { throw ProtocolError(code: .conflict, message: "busy: Android setup is running") }
            return withAccepted(sdk.path, known)
        }
        running = true   // before any await, like `begin`
        defer { running = false }
        return try await readLicenses()
    }

    /// Never accepts anything: answers `y` only to "Review licenses?" and `n` to each `Accept?`, and if
    /// `<sdk>/licenses/` changed anyway, restores it exactly and fails.
    private func readLicenses() async throws(ProtocolError) -> [License] {
        let sdk = sdk.path
        guard let sm = sdkmanagerPath(sdk), java != nil else { throw Self.notReady }
        let dir = URL(fileURLWithPath: sdk).appendingPathComponent("licenses")
        let before = Self.snapshot(dir)
        let r = try await sdkmanager(sm, ["--licenses", "--sdk_root=\(sdk)"], item: nil, answers: true, timeout: .seconds(300))
        if Self.snapshot(dir) != before {
            let failed = Self.restore(dir, before)
            throw ProtocolError(code: .internal, message: "sdkmanager --licenses changed \(dir.path) without consent; "
                                + (failed.isEmpty ? "restored it" : "could NOT restore: \(failed.joined(separator: ", "))"))
        }
        let parsed = AndroidSdk.parseLicenses(Self.splitHeaders(r.output)).filter { Self.safeId($0.id) }
        // declining may end in a nonzero exit: texts printed count, an exit without any is a failure
        guard r.status == 0 || !parsed.isEmpty else {
            throw ProtocolError(code: .unavailable, message: "sdkmanager --licenses failed (exit \(r.status)): \(Self.tail(r.output))")
        }
        known = parsed
        return withAccepted(sdk, parsed)
    }

    /// Starts the job and returns at once: `android.install` answers with this `{job}`. `busy` (`conflict`) while
    /// another job, `sdkmanager` or Android Studio runs. Errors after the start land in `status().job`.
    func start(accept ids: [String]) async throws(ProtocolError) -> AndroidStatus.Job {
        _ = try await begin(ids)
        return job ?? .init(phase: "prepare")
    }

    /// `start`, then waits for the end; throws what failed the job (`cancelled` when `cancel` stopped it).
    /// Phase 1 runs if needed; phase 2 only when `ids` cover every pending license, except right after phase 1 with no
    /// ids: the job then ends `done` and `status` says `needsLicense`. Retrying redoes only what is missing.
    func install(accept ids: [String]) async throws(ProtocolError) {
        let task = try await begin(ids)
        do { try await task.value } catch { throw error as? ProtocolError ?? ProtocolError(code: .internal, message: "\(error)") }
    }

    /// Stops the job: kills `sdkmanager`'s process group and cancels the download; phase 1's staging is removed by
    /// `prepare` as it unwinds. Never deletes anything else (what `sdkmanager` half-wrote in `<sdk>` is its own to clean).
    func cancel() {
        if running && work == nil { cancelRequested = true }
        work?.cancel()
        process?.terminate()
    }

    private func begin(_ ids: [String]) async throws(ProtocolError) -> Task<Void, Error> {
        guard !running else { throw ProtocolError(code: .conflict, message: "busy: Android setup is already running") }
        running = true   // before any await: a second call reentering the actor must see it
        cancelRequested = false
        let other = await othersRunning(Self.blocksForStudio(sdk: AndroidSdk.root(env: env, home: home), home: home))
        if other != nil || cancelRequested {
            running = false; cancelRequested = false
            throw other.map { ProtocolError(code: .conflict, message: "busy: \($0) is running; close it and try again") } ?? Self.cancelled
        }
        job = .init(phase: "prepare")
        let task = Task { try await self.run(ids) }
        work = task
        return task
    }

    private func run(_ ids: [String]) async throws {
        defer { running = false; work = nil; process = nil }
        do {
            let sdk = sdk.path   // one SDK for the whole job
            let prepares = sdkmanagerPath(sdk) == nil || java == nil
            try await prepare(progress: { item, bytes, total in Task { await self.downloaded(item, bytes, total) } })
            try Task.checkCancellation()
            guard let sm = sdkmanagerPath(sdk) else { throw Self.notReady }
            let missing = items(sdk).filter { $0.at == nil && Self.estimates[$0.id] != nil }.map(\.id)
            guard !missing.isEmpty else { job = .init(phase: "done", percent: 100); return }

            job = .init(phase: "install")
            let pending = try await readLicenses().filter { !$0.accepted }
            if !pending.allSatisfy({ ids.contains($0.id) }) {
                if prepares && ids.isEmpty { job = .init(phase: "done"); return }   // phase 1 only; the licenses are known now
                throw ProtocolError(code: .invalidArgs, message: "accept the Android SDK licenses first: "
                                    + pending.map(\.id).filter { !ids.contains($0) }.joined(separator: ", "))
            }
            let need = 2 * missing.reduce(Int64(0)) { $0 + Self.estimates[$1]! }
            if let free = freeSpace(sdk), free < need {
                throw ProtocolError(code: .unavailable, message: "not enough disk space: about \(need >> 20) MB needed in the SDK volume, \(free >> 20) MB free")
            }
            for l in pending { try accept(l, sdk) }
            for id in missing {
                job = .init(phase: "install", item: id, percent: 0)
                var pkg = id
                if id == "image" {
                    let r = try await sdkmanager(sm, ["--list", "--sdk_root=\(sdk)"], item: nil, timeout: .seconds(300))
                    guard r.status == 0, let p = AndroidSdk.pickLatestStable(AndroidSdk.parseImages(r.output)) else {
                        throw ProtocolError(code: .unavailable, message: "no stable google_apis arm64-v8a image in sdkmanager --list: \(Self.tail(r.output))")
                    }
                    pkg = p
                }
                let r = try await sdkmanager(sm, ["--sdk_root=\(sdk)", pkg], item: id, timeout: .seconds(3600))
                // sdkmanager can exit 0 having skipped a package whose license it does not see as accepted
                guard r.status == 0, items(sdk).first(where: { $0.id == id })?.at != nil else {
                    throw ProtocolError(code: .unavailable, message: "\(pkg): " + (r.status == 0
                        ? "sdkmanager did not install it (license not accepted?): " : "sdkmanager failed (exit \(r.status)): ") + Self.tail(r.output))
                }
                job?.percent = 100
            }
            job = .init(phase: "done", percent: 100)
        } catch {
            let e = error as? ProtocolError ?? (error is CancellationError ? Self.cancelled : ProtocolError(code: .unavailable, message: "\(error)"))
            if e == Self.cancelled { job = .init(phase: "cancelled", item: job?.item) } else { job?.phase = "failed"; job?.error = e.message }
            throw e
        }
    }

    private func downloaded(_ item: String, _ bytes: Int64, _ total: Int64) {
        guard running, job?.phase == "prepare" else { return }
        job = .init(phase: "prepare", item: item, percent: total > 0 ? Int(bytes * 100 / total) : nil, bytes: bytes, total: total)
    }

    /// Runs `sdkmanager args` through `/bin/sh` (stderr into stdout) in its own process group, `JAVA_HOME` set.
    /// `answers`: stdin is a pipe answered as the prompts appear: `y` to "Review licenses?" (show them), `n` to every
    /// `Accept?`; otherwise stdin is `/dev/null`. `item`: progress lines update `job.percent`. Killed by `cancel` or
    /// past `timeout` (`.timeout`).
    private func sdkmanager(_ sm: String, _ args: [String], item: String?, answers: Bool = false, timeout: Duration)
        async throws(ProtocolError) -> (status: Int32, output: String) {
        guard let java else { throw Self.notReady }
        if Task.isCancelled { throw Self.cancelled }
        enum Event: Sendable { case data(Data), exit(Int32) }
        let (events, sink) = AsyncStream<Event>.makeStream()
        let p = try LongProcess(executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", #"exec "$0" "$@" 2>&1"#, sm] + args,
                                env: ["PATH": "/usr/bin:/bin", "JAVA_HOME": java, "HOME": home], runDir: runDir, stdin: answers,
                                onData: { sink.yield(.data($0)) }, onExit: { sink.yield(.exit($0)); sink.finish() })
        process = p
        let timer = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            p.terminate(); return true
        }
        var out = Data(), status: Int32 = -1, reviewed = false, declined = 0
        for await e in events {   // ends early when the job is cancelled
            switch e {
            case .data(let d):
                if out.count < 1 << 20 { out.append(d) }
                // ponytail: a chunk cut mid-line just misses one redraw
                if let item, job?.item == item, let pr = AndroidSdk.parseProgress(String(decoding: d, as: UTF8.self)) { job?.percent = pr.percent }
                if answers {
                    // ponytail: rescans the output (capped at 1 MiB) per chunk; the licenses run prints a few KB
                    let text = String(decoding: out, as: UTF8.self)
                    if !reviewed, text.range(of: "Review license", options: .caseInsensitive) != nil {
                        reviewed = true; _ = p.write(Data("y\n".utf8))
                    }
                    let prompts = text.components(separatedBy: "Accept?").count - 1
                    while declined < prompts { declined += 1; _ = p.write(Data("n\n".utf8)) }
                }
            case .exit(let c): status = c
            }
        }
        if process === p { process = nil }
        timer.cancel()
        if Task.isCancelled { p.terminate(); throw Self.cancelled }
        if await timer.value { throw ProtocolError(code: .timeout, message: "sdkmanager \(args.first ?? "") timed out") }
        return (status, String(decoding: out, as: UTF8.self))
    }

    /// File name -> contents of `<sdk>/licenses/`; a missing dir is the same as an empty one.
    static func snapshot(_ dir: URL) -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, (try? Data(contentsOf: dir.appendingPathComponent($0))) ?? Data()) })
    }

    /// Puts `<sdk>/licenses/`'s files back as `snapshot` saw them (an empty dir may stay); returns the names it could not fix.
    static func restore(_ dir: URL, _ old: [String: Data]) -> [String] {
        let fm = FileManager.default
        var failed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old[name] == nil {
            do { try fm.removeItem(at: dir.appendingPathComponent(name)) } catch { failed.append(name) }
        }
        for (name, data) in old {
            do { try data.write(to: dir.appendingPathComponent(name), options: .atomic) } catch { failed.append(name) }
        }
        return failed
    }

    private func withAccepted(_ sdk: String, _ l: [(id: String, title: String, text: String)]) -> [License] {
        l.map { l in
            let lines = ((try? String(contentsOfFile: "\(sdk)/licenses/\(l.id)", encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline)
            let hash = Self.licenseHash(l.text)
            return License(id: l.id, title: l.title, text: l.text, accepted: lines.contains { $0.trimmingCharacters(in: .whitespaces) == hash })
        }
    }

    /// Appends the text's hash as a line of `<sdk>/licenses/<id>`, the file `sdkmanager --licenses` writes on "y".
    private func accept(_ l: License, _ sdk: String) throws {
        let dir = URL(fileURLWithPath: sdk).appendingPathComponent("licenses")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(l.id)
        try (((try? Data(contentsOf: f)) ?? Data()) + Data("\n\(Self.licenseHash(l.text))".utf8)).write(to: f, options: .atomic)
    }

    /// UNVERIFIED until the Task 6 E2E (real sdkmanager, temp SDK): assumes sdkmanager stores the SHA-1 (lowercase hex)
    /// of the license text as it prints it, trimmed. If wrong, sdkmanager skips the package and the job fails with
    /// "did not install it (license not accepted?)" naming it; fix the rule here.
    static func licenseHash(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The id names a file in `<sdk>/licenses/`: no path pieces.
    static func safeId(_ id: String) -> Bool { id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil }

    /// Real `--licenses` prints `1/7: License <id>:`, possibly right after the unanswered `Accept? (y/N): `: put each
    /// header alone on its line, as `parseLicenses` expects.
    static func splitHeaders(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "(?m)(^|[0-9]+/[0-9]+: )(License [A-Za-z0-9._-]+:)[ \\t]*$", with: "\n$2", options: .regularExpression)
    }

    /// The last lines of an output, for an error message.
    static func tail(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(3).joined(separator: " | ")
    }

    /// Android Studio only blocks an install into its own SDK (`<home>/Library/Android/sdk`).
    static func blocksForStudio(sdk: String, home: String) -> Bool {
        URL(fileURLWithPath: sdk).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: "\(home)/Library/Android/sdk").resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Another `sdkmanager` (any process with it in its arguments, anywhere) or, when `studioBlocks`, Android Studio
    /// (`studio`), via `pgrep`.
    static let others: @Sendable (Bool) async -> String? = { studioBlocks in
        for (name, args) in [("another sdkmanager", ["-f", "sdkmanager"]), ("Android Studio", ["-x", "studio"])]
        where studioBlocks || name != "Android Studio" {
            let r = try? await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/pgrep"), args: args,
                                                  in: URL(fileURLWithPath: "/"), env: [:], timeout: .seconds(5))
            if r?.status == 0 { return name }
        }
        return nil
    }
}
