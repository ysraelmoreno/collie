import Foundation

/// The design engine this Collie build accepts (`Resources/figcraft-engine.json`, in the signed bundle): the exact
/// asset an install downloads (url, sizes, sha256) and whose Developer ID team signs it.
struct FigcraftPin: Codable, Equatable, Sendable {
    var version, figcraft, commit, inputs, url: String
    var size, unpackedSize: Int64
    var sha256, teamId: String

    /// nil: missing or unreadable (a local build without the pin: no App Support engine can run).
    static func load(_ file: URL) -> FigcraftPin? {
        guard let d = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(FigcraftPin.self, from: d)
    }
}

/// A figcraft dir that can run (`bin/figcraft-server`, `bin/figcraft-cli`, `web/`) and where it came from.
/// Only the daemon resolves it; the Design panel serves the `web` the daemon hands back in `design.link`.
struct FigcraftEngine: Equatable, Sendable {
    enum Source: String, Codable, Sendable { case env, bundle, appSupport, vendor }
    var dir: URL
    /// `engine.json`'s version (nil: none, e.g. an env or vendor build).
    var version: String?
    var source: Source
    var web: URL { dir.appendingPathComponent("web") }

    /// Written by the installer: the sha256 of the asset this App Support engine came from.
    static let marker = ".collie-installed"

    /// env (taken as is, like the old `figcraftDir`) → bundle → App Support → vendor (DEBUG only; callers pass nil otherwise). The bundle goes before App Support
    /// (owner decision P2: a release bundle never has an engine, so this only decides local builds, where the one just
    /// built wins). App Support runs only when its marker is the pin's sha256 (owner decision P1).
    static func resolve(env: URL?, bundle: URL?, appSupport: URL, vendor: URL?, pin: FigcraftPin?) -> FigcraftEngine? {
        if let env { return FigcraftEngine(dir: env, version: nil, source: .env) }   // as is: a missing binary fails at start
        if let bundle, isValid(bundle) { return FigcraftEngine(dir: bundle, version: version(bundle), source: .bundle) }
        if isValid(appSupport), let pin, installedSha(appSupport) == pin.sha256 {
            return FigcraftEngine(dir: appSupport, version: version(appSupport), source: .appSupport)
        }
        if let vendor, isValid(vendor) { return FigcraftEngine(dir: vendor, version: version(vendor), source: .vendor) }
        return nil
    }

    static func isValid(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: dir.appendingPathComponent("bin/figcraft-server").path)
            && fm.isExecutableFile(atPath: dir.appendingPathComponent("bin/figcraft-cli").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("web/index.html").path)
    }

    static func version(_ dir: URL) -> String? {
        struct Info: Decodable { var version: String }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("engine.json")) else { return nil }
        return (try? JSONDecoder().decode(Info.self, from: d))?.version
    }

    static func installedSha(_ dir: URL) -> String? {
        (try? String(contentsOf: dir.appendingPathComponent(marker), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `X.Y.Z` numerically, then `N` of `-cN`; missing parts count as 0.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ v: String) -> [Int] {
            let halves = v.split(separator: "-", maxSplits: 1)
            var p = (halves.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            while p.count < 3 { p.append(0) }
            let c = halves.count > 1 && halves[1].hasPrefix("c") ? Int(halves[1].dropFirst()) ?? 0 : 0
            return Array(p.prefix(3)) + [c]
        }
        for (x, y) in zip(parts(a), parts(b)) where x != y { return x < y ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    /// Where an install stages (always the throwaway side of a swap): an orphan is removed at daemon start.
    static func staging(root: URL) -> URL { root.appendingPathComponent(".figcraft-staging") }

    static func cleanStaging(root: URL) { try? FileManager.default.removeItem(at: staging(root: root)) }

    /// For the UI and the errors: `running` is `resolve`'s answer; a valid `appSupport` that does not run needs an update
    /// (or a reinstall when it is not older than the pin, has no marker, or is the pin's version with another hash).
    static func state(running: FigcraftEngine?, appSupport: URL, pin: FigcraftPin?) -> EngineState {
        if let running { return .installed(running) }
        guard isValid(appSupport), let pin else { return .absent }
        let installed = version(appSupport)
        let reinstall = installedSha(appSupport) == nil
            || installed.map { compareVersions($0, pin.version) != .orderedAscending } ?? true
        return .needsUpdate(installed: installed, pinned: pin.version, reinstall: reinstall)
    }
}

enum EngineState: Equatable, Sendable {
    case absent
    case installed(FigcraftEngine)
    case needsUpdate(installed: String?, pinned: String, reinstall: Bool)
}
