import Foundation
import CollieProtocol

/// `collie open` (R4): `/usr/bin/open` is denied inside the sandbox, and the terminal's `open` shim asks the daemon,
/// which runs it outside the sandbox for http(s)/mailto URLs and installed apps only. Never scripts, `.command`/`.tool`,
/// executables, folders or documents (any of them would run code, or open a handler, outside the sandbox).
enum OpenCommand {
    /// Where an app may come from: places a sandboxed terminal can't write. ponytail: an app the agent built (in the
    /// project, DerivedData) is refused too, since it could be any code; the user opens those from Xcode or Finder.
    static func appRoots(home: URL) -> [URL] {
        ["/Applications", "/System/Applications", "/System/Library/CoreServices"].map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent("Applications")]
    }
    /// Where `--app <name>` is looked up (`open -a Simulator`).
    static func appSearchDirs(home: URL) -> [URL] {
        let xcodes = ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.sorted()
            .map { "/Applications/\($0)/Contents/Developer/Applications" }
        return (["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"] + xcodes)
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
    }

    /// The `/usr/bin/open` arguments for `target` (a URL or an app bundle) and/or `app` (`-a`), relative paths
    /// against `cwd`; throws `invalidArgs` naming what is refused.
    static func arguments(target: String?, app: String?, cwd: String?, home: URL) throws(ProtocolError) -> [String] {
        func refuse(_ what: String) -> ProtocolError {
            ProtocolError(code: .invalidArgs, message: "collie open: only http(s)/mailto URLs and installed apps (.app in /Applications); refused: \(what)")
        }
        let roots = appRoots(home: home).map { URL(fileURLWithPath: SignedAppCheck.realPath($0)) }
        func bundle(_ p: String) throws(ProtocolError) -> String {
            let abs = p.hasPrefix("/") ? URL(fileURLWithPath: p) : URL(fileURLWithPath: cwd ?? "/").appendingPathComponent(p)
            let real = URL(fileURLWithPath: SignedAppCheck.realPath(abs))
            var dir: ObjCBool = false
            guard real.pathExtension == "app", FileManager.default.fileExists(atPath: real.path, isDirectory: &dir), dir.boolValue,
                  roots.contains(where: { real.pathComponents.starts(with: $0.pathComponents) }) else { throw refuse(p) }
            return real.path
        }
        var out: [String] = []
        if let app, !app.isEmpty {
            if app.contains("/") { out += ["-a", try bundle(app)] } else {
                let name = app.hasSuffix(".app") ? app : app + ".app"
                guard !name.hasPrefix("."), let hit = appSearchDirs(home: home).map({ $0.appendingPathComponent(name).path })
                        .first(where: { FileManager.default.fileExists(atPath: $0) }) else { throw refuse(app) }
                out += ["-a", try bundle(hit)]
            }
        }
        if let target, !target.isEmpty {
            if let scheme = URL(string: target)?.scheme?.lowercased(), target.contains(":"), !target.hasPrefix("/") {
                guard ["http", "https", "mailto"].contains(scheme) else { throw refuse(target) }
                out.append(target)
            } else {
                guard app == nil || app?.isEmpty == true else { throw refuse(target) }   // `-a X file`: a document
                out.append(try bundle(target))
            }
        }
        guard !out.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "collie open: missing URL or --app") }
        return out
    }

    /// Runs `/usr/bin/open` (outside any terminal's sandbox: the daemon isn't in one).
    static let live: @Sendable ([String]) async throws(ProtocolError) -> Void = { args throws(ProtocolError) in
        let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/open"), args: args, in: URL(fileURLWithPath: "/"),
                                             env: ["PATH": "/usr/bin:/bin"], timeout: .seconds(15))
        guard r.status == 0 else {
            throw ProtocolError(code: .invalidArgs, message: "open failed: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
