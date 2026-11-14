import Foundation
import CollieDevice
import CollieProtocol

/// Runs `executable args` in `dir`; throws unless it exits 0. The daemon's is `AndroidInstaller.run` (`BoundedProcess`:
/// own process group, stdin /dev/null, killed past the timeout).
typealias AndroidRunner = @Sendable (_ executable: String, _ args: [String], _ dir: URL) async throws -> Void

/// Installs the Android SDK pieces Collie downloads itself. Phase 1, `prepare`: Collie's JDK (only when no usable Java)
/// and `cmdline-tools` (only when no usable one), downloaded and extracted in `<sdk>/.collie-staging/prepare/`, moved into
/// place only once checksummed and extracted. The staging is removed on success and failure; nothing outside it is
/// deleted or overwritten.
actor AndroidInstaller {
    /// The daemon's root. ponytail: unused by phase 1; kept for the job/log state phase 2 adds.
    let root: URL
    let env: [String: String], home: String
    let fetch: AndroidFetch, runner: AndroidRunner
    let isAppleSilicon: Bool, javaCandidates: [String]?
    /// Bytes free on the volume holding a path (`nil`: unknown, not checked).
    let freeSpace: @Sendable (String) -> Int64?

    init(root: URL, env: [String: String], home: String, fetch: @escaping AndroidFetch = AndroidDownload.fetch,
         runner: @escaping AndroidRunner = AndroidInstaller.run, isAppleSilicon: Bool = AndroidInstaller.appleSilicon,
         javaCandidates: [String]? = nil, freeSpace: @escaping @Sendable (String) -> Int64? = AndroidInstaller.free) {
        self.root = root; self.env = env; self.home = home; self.fetch = fetch; self.runner = runner
        self.isAppleSilicon = isAppleSilicon; self.javaCandidates = javaCandidates; self.freeSpace = freeSpace
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
