import Foundation

/// What one plug-in helper run may touch (PRD G3).
struct PluginHelperInput: Sendable {
    var helper: URL
    var pluginDir: URL
    var project: URL
    var dataDir: URL
}

/// The helper's own Seatbelt profile: `(deny default)`; reads the project, its own folder and the system's libraries;
/// writes only its data dir (and `/dev/null`); no network, no Unix sockets, no home. One allow per line.
enum PluginHelperProfile {
    static func render(_ i: PluginHelperInput) -> String {
        func real(_ u: URL) -> String { SignedAppCheck.realPath(u) }
        let q = SandboxProfile.q
        let helper = real(i.helper), plugin = real(i.pluginDir), project = real(i.project), data = real(i.dataDir)
        // a script helper needs its interpreter: `sh`/`bash`/`env` and what else the system ships in the two bin dirs
        let exes = ["(literal \(q(i.helper.path)))", "(literal \(q(helper)))", "(literal \"/bin/sh\")", "(literal \"/bin/bash\")",
                    "(literal \"/usr/bin/env\")", "(subpath \"/usr/bin\")", "(subpath \"/bin\")"]
        // measured with an `sh` helper: the dyld cache and the system's libraries; "/" itself (dyld aborts without it)
        let sys = ["/System", "/usr/lib", "/usr/share", "/usr/bin", "/bin", "/private/var/db/dyld", "/dev"].map { "(subpath \(q($0)))" }
            + ["(literal \"/\")"]
        let reads = sys + [plugin, project, data].map { "(subpath \(q($0)))" }
        // path lookup: the ancestors of what is readable can be stat'ed, never listed or read
        var ancestors: Set<String> = ["/"]
        for p in [helper, i.helper.path, plugin, project, data] {
            var u = URL(fileURLWithPath: p).deletingLastPathComponent()
            while u.pathComponents.count > 1 { ancestors.insert(u.path); u = u.deletingLastPathComponent() }
        }
        var out = ["(version 1)", "(deny default)", "(allow process-fork)", "(allow sysctl-read)"]
        out += exes.map { "(allow process-exec \($0))" }
        out += reads.map { "(allow file-read* \($0))" }
        out += ancestors.sorted().map { "(allow file-read-metadata (literal \(q($0))))" }
        out += ["(allow file-write* (subpath \(q(data))))", "(allow file-write* (literal \"/dev/null\"))"]
        return out.joined(separator: "\n") + "\n"
    }

    /// `/usr/bin/sandbox-exec -p <profile> <helper>`
    static func command(_ i: PluginHelperInput, profile: String) -> (executable: URL, args: [String]) {
        (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile, i.helper.path])
    }
}
