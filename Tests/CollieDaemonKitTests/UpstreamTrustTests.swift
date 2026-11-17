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
        #expect(ders(TrustSnapshot(anchors: [], admin: [entry("Example Internal Root CA")], user: [])) == [der("Example Internal Root CA")])
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

    /// The corporate machine's shape (Task 0): TLSProxy's root and its signing intermediate.
    // ponytail: ajustar à tabela da Task 0 (Policy/Result reais ainda não vieram; raiz com settings vazias)
    @Test func tlsproxyRootIn() {
        let s = TrustSnapshot(anchors: [], admin: [entry("ca.example.com")], user: [])
        #expect(ders(s) == [der("ca.example.com")])
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
