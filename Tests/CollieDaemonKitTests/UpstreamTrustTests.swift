import Testing
import Foundation
@testable import CollieDaemonKit

/// The rule works on DER as opaque bytes: fixtures are names, never real certificates.
@Suite struct UpstreamTrustTests {
    private func der(_ name: String) -> Data { Data(name.utf8) }
    private func entry(_ name: String, selfSigned: Bool = true, _ settings: [TrustSetting] = []) -> TrustEntry {
        TrustEntry(der: der(name), selfSigned: selfSigned, settings: settings)
    }
    private func ders(_ s: TrustSnapshot) -> [Data] {
        UpstreamTrust.bundle(s).pem.components(separatedBy: "-----BEGIN CERTIFICATE-----\n").dropFirst().map {
            Data(base64Encoded: $0.components(separatedBy: "\n-----END CERTIFICATE-----").first!, options: .ignoreUnknownCharacters)!
        }
    }
    private let ssl = UpstreamTrust.sslOID

    @Test func anchorIn() {
        let s = TrustSnapshot(anchors: [der("USERTrust RSA Certification Authority")], admin: [], user: [])
        #expect(ders(s) == [der("USERTrust RSA Certification Authority")])
        #expect(UpstreamTrust.bundle(s).count == 1)
    }

    @Test func adminEmptySettingsIn() {
        #expect(ders(TrustSnapshot(anchors: [], admin: [entry("Corp Internal Root CA")], user: [])) == [der("Corp Internal Root CA")])
    }

    @Test func trustRootSelfSignedIn() {
        let s = TrustSnapshot(anchors: [], admin: [entry("r", [TrustSetting(result: 1, policyOID: ssl, policyString: nil)])], user: [])
        #expect(ders(s) == [der("r")])
    }

    @Test func trustRootNotSelfSignedOut() {
        let s = TrustSnapshot(anchors: [], admin: [entry("i", selfSigned: false, [TrustSetting(result: 1, policyOID: nil, policyString: nil)])], user: [])
        #expect(ders(s).isEmpty)
    }

    @Test func trustAsRootNotSelfSignedIn() {
        let s = TrustSnapshot(anchors: [], admin: [entry("i", selfSigned: false, [TrustSetting(result: 2, policyOID: ssl, policyString: nil)])], user: [])
        #expect(ders(s) == [der("i")])
    }

    @Test func trustAsRootSelfSignedOut() {
        let s = TrustSnapshot(anchors: [], admin: [entry("r", [TrustSetting(result: 2, policyOID: nil, policyString: nil)])], user: [])
        #expect(ders(s).isEmpty)
    }

    @Test func missingResultIsTrustRoot() {
        let s = TrustSnapshot(anchors: [], admin: [], user: [entry("r", [TrustSetting(result: nil, policyOID: ssl, policyString: nil)])])
        #expect(ders(s) == [der("r")])
    }

    @Test func policyStringOut() {
        let s = TrustSnapshot(anchors: [], admin: [entry("r", [TrustSetting(result: 1, policyOID: ssl, policyString: "a.example")])], user: [])
        #expect(ders(s).isEmpty)
    }

    @Test func nonSSLPolicyOut() {
        let codeSigning = "1.2.840.113635.100.1.16"
        let s = TrustSnapshot(anchors: [], admin: [], user: [entry("r", [TrustSetting(result: 1, policyOID: codeSigning, policyString: nil)])])
        #expect(ders(s).isEmpty)
    }

    @Test func oneValidSettingAmongOthersIn() {
        let s = TrustSnapshot(anchors: [], admin: [entry("r", [TrustSetting(result: 1, policyOID: "1.2.840.113635.100.1.16", policyString: nil),
                                                              TrustSetting(result: 1, policyOID: ssl, policyString: nil)])], user: [])
        #expect(ders(s) == [der("r")])
    }

    @Test func unspecifiedOut() {
        let s = TrustSnapshot(anchors: [], admin: [entry("r", [TrustSetting(result: 4, policyOID: nil, policyString: nil)])], user: [])
        #expect(ders(s).isEmpty)
    }

    @Test func denyOut() {
        let s = TrustSnapshot(anchors: [], admin: [entry("r", [TrustSetting(result: 3, policyOID: nil, policyString: nil)])], user: [])
        #expect(ders(s).isEmpty)
        #expect(UpstreamTrust.bundle(s).denied == 1)
    }

    @Test func denyRemovesAnchor() {
        let s = TrustSnapshot(anchors: [der("a"), der("b")], admin: [],
                              user: [entry("a", [TrustSetting(result: 3, policyOID: ssl, policyString: nil)])])
        let b = UpstreamTrust.bundle(s)
        #expect(ders(s) == [der("b")])
        #expect(b.count == 1 && b.denied == 1)
    }

    @Test func dedupeByDER() {
        let s = TrustSnapshot(anchors: [der("a"), der("a")], admin: [entry("a")], user: [entry("a")])
        #expect(ders(s) == [der("a")])
        #expect(UpstreamTrust.bundle(s).count == 1)
    }

    @Test func stableOrder() {
        let s = TrustSnapshot(anchors: [der("z")], admin: [entry("m")], user: [entry("a")])
        #expect(ders(s) == [der("z"), der("m"), der("a")])
    }

    /// The corporate machine (Task 0, validated by the owner): in the admin domain, TLSProxy's root and its signing
    /// intermediate both have "Number of trust settings : 0". An empty list is full trust, self-signed or not.
    @Test func tlsproxyRootIn() {
        let s = TrustSnapshot(anchors: [], admin: [entry("ca.example.com"), entry("eproxy.ca.example.com", selfSigned: false),
                                                   entry("Corp Internal Root CA")], user: [])
        #expect(ders(s) == [der("ca.example.com"), der("eproxy.ca.example.com"), der("Corp Internal Root CA")])
    }

    @Test func tlsproxyIntermediateTrustRootOut() {
        let s = TrustSnapshot(anchors: [], admin: [entry("eproxy.ca.example.com", selfSigned: false,
                                                         [TrustSetting(result: 1, policyOID: nil, policyString: nil)])], user: [])
        #expect(ders(s).isEmpty)
    }

    @Test func emptySnapshotCountsZero() {
        let b = UpstreamTrust.bundle(TrustSnapshot(anchors: [], admin: [], user: []))
        #expect(b.count == 0 && b.pem.isEmpty && b.denied == 0)
    }

    @Test func pemFormat() {
        let big = Data((0..<200).map { UInt8($0) })
        let pem = UpstreamTrust.bundle(TrustSnapshot(anchors: [big, der("x")], admin: [], user: [])).pem
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        #expect(pem.hasSuffix("-----END CERTIFICATE-----\n"))
        #expect(pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 3)
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
        #expect(body.allSatisfy { $0.count <= 64 })
        #expect(body.first?.count == 64)
    }

    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-trust-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("upstream-ca.pem")
    }

    @Test func writeReplacesWhenChanged() throws {
        let f = try tempFile()
        defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        #expect(try UpstreamTrust.write("one", to: f))
        #expect(try UpstreamTrust.write("two", to: f))
        #expect(try String(contentsOf: f, encoding: .utf8) == "two")
        let left = try FileManager.default.contentsOfDirectory(atPath: f.deletingLastPathComponent().path)
        #expect(left == ["upstream-ca.pem"])   // no temp left behind
    }

    @Test func unchangedWriteKeepsInode() throws {
        let f = try tempFile()
        defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        #expect(try UpstreamTrust.write("same", to: f))
        let inode = try FileManager.default.attributesOfItem(atPath: f.path)[.systemFileNumber] as? Int
        #expect(try UpstreamTrust.write("same", to: f) == false)
        #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.systemFileNumber] as? Int == inode)
    }
}

/// `resolve` and the user's `config.yaml` (Task 2). Snapshots are fixtures; files live in a temp dir.
@Suite struct UpstreamResolveTests {
    private let snap = TrustSnapshot(anchors: [Data("USERTrust RSA Certification Authority".utf8)],
                                     admin: [TrustEntry(der: Data("ca.example.com".utf8), selfSigned: true, settings: [])], user: [])
    private struct Boom: Error {}

    private func dirs() throws -> (confdir: URL, out: URL, base: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("collie-resolve-\(UUID().uuidString.prefix(8))")
        let confdir = base.appendingPathComponent("network/mitm")
        try FileManager.default.createDirectory(at: confdir, withIntermediateDirectories: true)
        return (confdir, base.appendingPathComponent("network/upstream-ca.pem"), base)
    }
    private func config(_ confdir: URL, _ text: String, name: String = "config.yaml") throws {
        try Data(text.utf8).write(to: confdir.appendingPathComponent(name))
    }
    private func resolve(_ confdir: URL, _ out: URL, snapshot: () throws -> TrustSnapshot, calls: inout Int, logs: inout [String]) -> UpstreamCA {
        var c = 0, l: [String] = []
        let r = UpstreamTrust.resolve(confdir: confdir, out: out, snapshot: { c += 1; return try snapshot() }, log: { l.append($0) })
        calls = c; logs = l
        return r
    }

    @Test(arguments: ["ssl_verify_upstream_trusted_ca: /x.pem", "ssl_verify_upstream_trusted_confdir: /d", "ssl_insecure: true",
                      "ssl_insecure: True  # mine"])
    func configDecides(_ line: String) throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try config(d.confdir, "listen_port: 8080\n" + line + "\n")
        var calls = 0, logs: [String] = []
        let r = resolve(d.confdir, d.out, snapshot: { snap }, calls: &calls, logs: &logs)
        #expect(r.mode == .userConfig && r.url == nil && calls == 0)
        #expect(!FileManager.default.fileExists(atPath: d.out.path))
    }

    @Test func configYmlAlsoDecides() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try config(d.confdir, "ssl_verify_upstream_trusted_ca: /x.pem\n", name: "config.yml")
        #expect(UpstreamTrust.userConfig(d.confdir).decides)
    }

    @Test(arguments: ["ssl_insecure: false", "# ssl_insecure: true", "  ssl_verify_upstream_trusted_ca: /x.pem",
                      "ssl_insecure_extra: true", "ssl_verify_upstream_trusted_ca_x: 1"])
    func doesNotDecide(_ line: String) throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try config(d.confdir, line + "\n")
        #expect(UpstreamTrust.userConfig(d.confdir) == UpstreamTrust.UserConfig(decides: false, insecure: false))
    }

    /// Known limit: a quoted key is not seen, so the status says `system` while mitmdump follows the file.
    @Test func quotedKeyIsEstimate() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try config(d.confdir, "\"ssl_insecure\": true\n")
        #expect(UpstreamTrust.userConfig(d.confdir).decides == false)
    }

    @Test func configYamlNotRegularIsIgnored() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        let yaml = d.confdir.appendingPathComponent("config.yaml"), yml = d.confdir.appendingPathComponent("config.yml")
        #expect(mkfifo(yaml.path, 0o600) == 0)   // a FIFO would block a plain read forever
        try FileManager.default.createDirectory(at: yml, withIntermediateDirectories: false)
        #expect(UpstreamTrust.userConfig(d.confdir).decides == false)
    }

    @Test func configYamlSymlinkIsIgnored() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        let real = d.base.appendingPathComponent("elsewhere.yaml")
        try Data("ssl_insecure: true\n".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: d.confdir.appendingPathComponent("config.yaml"), withDestinationURL: real)
        #expect(UpstreamTrust.userConfig(d.confdir).decides == false)
    }

    @Test func configYamlOver64KiBIsIgnored() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try config(d.confdir, "ssl_insecure: true\n" + String(repeating: "#", count: 65_536) + "\n")
        #expect(UpstreamTrust.userConfig(d.confdir).decides == false)
    }

    @Test func insecureTrueLogs() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try config(d.confdir, "ssl_insecure: true\n")
        var calls = 0, logs: [String] = []
        _ = resolve(d.confdir, d.out, snapshot: { snap }, calls: &calls, logs: &logs)
        #expect(logs.count == 1 && logs[0].contains("ssl_insecure"))
    }

    @Test func resolveWritesAndReturnsSystem() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        var calls = 0, logs: [String] = []
        let r = resolve(d.confdir, d.out, snapshot: { snap }, calls: &calls, logs: &logs)
        #expect(r == UpstreamCA(url: d.out, mode: .system, certs: 2, reason: nil))
        #expect(try String(contentsOf: d.out, encoding: .utf8) == UpstreamTrust.bundle(snap).pem)
        #expect(logs.isEmpty)
    }

    @Test func emptySnapshotIsUnavailable() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        var calls = 0, logs: [String] = []
        let r = resolve(d.confdir, d.out, snapshot: { TrustSnapshot(anchors: [], admin: [], user: []) }, calls: &calls, logs: &logs)
        #expect(r.mode == .unavailable && r.url == nil && r.reason != nil && logs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: d.out.path))
    }

    @Test func failureKeepsExistingFile() throws {
        let d = try dirs(); defer { try? FileManager.default.removeItem(at: d.base) }
        try Data("old".utf8).write(to: d.out)
        var calls = 0, logs: [String] = []
        let r = resolve(d.confdir, d.out, snapshot: { throw Boom() }, calls: &calls, logs: &logs)
        #expect(r.mode == .unavailable && r.url == nil)
        #expect(try String(contentsOf: d.out, encoding: .utf8) == "old")   // another session's mitmdump may read it late
        #expect(logs.count == 1 && !logs[0].contains("BEGIN") && !logs[0].contains("tlsproxy"))
    }
}
