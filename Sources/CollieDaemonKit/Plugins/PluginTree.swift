import Foundation
import CollieCore
import CollieProtocol

/// `collie plugin tree-hash` (PRD M4): the CI computes a catalog's `treeSha256` with the install's own `scan` (limits,
/// no links, no special files) and `treeHash`, so it is the number installed.json pins.
public enum PluginTree {
    public static func hash(_ root: URL) throws(ProtocolError) -> String {
        try PluginStore.treeHash(root, PluginStore.scan(root))
    }

    /// A helper's signature: its Developer ID team and code identifier; nil when not signed by a Developer ID.
    public typealias Signature = @Sendable (URL) async -> (team: String, identifier: String)?

    /// `collie plugin validate` (PRD T1, the `collie-plugins` check): what the install refuses (`scan`, `load`,
    /// apiVersion 1) plus the curated catalog's rules: `permissions.network` empty, and a helper that is a Mach-O
    /// signed by its author's Developer ID as `dev.collie.plugin.<id>`. Problems one per line (empty: ok); `team` is
    /// the helper's TeamIdentifier, the catalog's `helperTeamId`.
    public static func validate(_ root: URL, signature: Signature = developerID) async -> (problems: [String], team: String?) {
        var p: [String] = []
        do { _ = try PluginStore.scan(root) } catch { p.append(error.message) }
        var loaded: PluginManifest?
        do { loaded = try PluginManifest.load(folder: root) } catch { p.append(error.message) }
        // the load's refusal of a network list is the generic "newer"; this says what the catalog wants
        if let raw = try? Data(contentsOf: root.appendingPathComponent(PluginManifest.fileName)),
           let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let perms = o["permissions"] as? [String: Any], let net = perms["network"], (net as? [Any])?.isEmpty != true {
            p.append("permissions.network precisa ser vazio: plug-in do catálogo não usa rede")
        }
        guard let m = loaded else { return (p, nil) }
        if m.apiVersion != 1 { p.append("apiVersion \(m.apiVersion): o catálogo só aceita apiVersion 1") }
        guard let h = m.helper else { return (p, nil) }
        let bin = root.appendingPathComponent(h)
        guard machO(bin) else { p.append("helper '\(h)' não é um executável Mach-O"); return (p, nil) }
        guard let s = await signature(bin) else {
            p.append("helper '\(h)' sem assinatura Developer ID válida (codesign -dv: TeamIdentifier)")
            return (p, nil)
        }
        if s.identifier != "dev.collie.plugin.\(m.id)" {
            p.append("helper '\(h)' assinado como '\(s.identifier)': precisa ser dev.collie.plugin.\(m.id)")
        }
        return (p, s.team)
    }

    /// A regular file starting with a Mach-O (thin or fat) magic.
    static func machO(_ u: URL) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: u.path)[.type] as? FileAttributeType) == .typeRegular,
              let fh = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? fh.close() }
        guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return false }
        return [[0xcf, 0xfa, 0xed, 0xfe], [0xce, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]].contains(Array(d))
    }

    /// `codesign -dv` for the team and identifier, then the strict Developer ID requirement of that team.
    public static let developerID: Signature = { bin in
        guard let r = try? await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"), args: ["-dv", bin.path],
                                                    in: bin.deletingLastPathComponent(), env: ["PATH": "/usr/bin:/bin"],
                                                    timeout: .seconds(30)), r.status == 0 else { return nil }
        func field(_ k: String) -> String? {
            (r.stderr + "\n" + r.stdout).split(separator: "\n").first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) }
        }
        guard let team = field("TeamIdentifier"), let ident = field("Identifier"),
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              CodeSignature.signedByTeam(bin, identifier: ident, teamId: team) else { return nil }
        return (team, ident)
    }
}
