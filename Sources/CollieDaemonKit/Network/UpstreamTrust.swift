import Foundation
import Security

/// One trust-settings item (`SecTrustSettingsCopyTrustSettings`): result (`kSecTrustSettingsResult`), policy OID,
/// policy string (`kSecTrustSettingsPolicyString`, a host restriction).
struct TrustSetting: Sendable, Equatable {
    var result: Int?
    var policyOID: String?
    var policyString: String?
}

/// A certificate with trust settings in the admin or user domain.
struct TrustEntry: Sendable, Equatable {
    var der: Data
    var selfSigned: Bool
    var settings: [TrustSetting]
}

/// What the Keychain says, as data: the rule below never touches Security.framework, so tests pass fixtures.
struct TrustSnapshot: Sendable, Equatable {
    /// `SecTrustCopyAnchorCertificates`: the system domain plus admin/user certificates with empty trust settings.
    var anchors: [Data]
    var admin: [TrustEntry]
    var user: [TrustEntry]
}

/// The CAs macOS trusts, as a PEM for mitmdump's `ssl_verify_upstream_trusted_ca` (spec
/// `2026-11-17-network-upstream-trust-design.md`). Only public certificates; the user's "never trust" is honoured,
/// Apple's own distrust list and trustd restrictions are not visible here (documented limit).
enum UpstreamTrust {
    /// Apple's SSL policy (`kSecPolicyAppleSSL`).
    static let sslOID = "1.2.840.113635.100.1.3"

    /// Anchors, then admin, then user; deduped by DER; any `Deny` (3) in admin/user removes that DER everywhere.
    /// An admin/user certificate counts when its settings are empty or one item applies to SSL (no policy or the SSL
    /// one, no policy string) with TrustRoot (1, or absent) on a self-signed certificate or TrustAsRoot (2) on one
    /// that is not. Rule after Go 1.14's `root_cgo_darwin.go`.
    static func bundle(_ s: TrustSnapshot) -> (pem: String, count: Int, denied: Int) {
        let entries = s.admin + s.user
        let denied = Set(entries.filter { $0.settings.contains { $0.result == 3 } }.map(\.der))
        let trusted = entries.filter { e in
            e.settings.isEmpty || e.settings.contains { t in
                guard t.policyString == nil, t.policyOID == nil || t.policyOID == sslOID else { return false }
                let r = t.result ?? 1
                return r == 1 && e.selfSigned || r == 2 && !e.selfSigned
            }
        }.map(\.der)
        var seen = Set<Data>(), out: [Data] = []
        for d in s.anchors + trusted where !denied.contains(d) && seen.insert(d).inserted { out.append(d) }
        let pem = out.map {
            "-----BEGIN CERTIFICATE-----\n" + $0.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                + "\n-----END CERTIFICATE-----\n"
        }.joined()
        return (pem, out.count, denied.count)
    }

    /// Atomic (temp in the same directory, then rename) and only when the bytes differ: a mitmdump reads the file late,
    /// at its first upstream handshake, so it is never removed or half-written. True when the file was replaced.
    static func write(_ pem: String, to url: URL) throws -> Bool {
        let data = Data(pem.utf8)
        if let old = try? Data(contentsOf: url), old == data { return false }
        try data.write(to: url, options: .atomic)
        return true
    }

    /// The real source: anchors plus the admin and user trust settings. No password, no dialog (read only).
    static func systemSnapshot() throws -> TrustSnapshot {
        var anchors: CFArray?
        let st = SecTrustCopyAnchorCertificates(&anchors)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        let der = ((anchors as? [SecCertificate]) ?? []).map { SecCertificateCopyData($0) as Data }
        return TrustSnapshot(anchors: der, admin: try entries(.admin), user: try entries(.user))
    }

    private static func entries(_ domain: SecTrustSettingsDomain) throws -> [TrustEntry] {
        var certs: CFArray?
        let st = SecTrustSettingsCopyCertificates(domain, &certs)
        if st == errSecNoTrustSettings { return [] }
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        return ((certs as? [SecCertificate]) ?? []).map { c in
            var raw: CFArray?
            SecTrustSettingsCopyTrustSettings(c, domain, &raw)
            let settings = ((raw as? [[String: Any]]) ?? []).map { d in
                TrustSetting(result: (d[kSecTrustSettingsResult as String] as? NSNumber)?.intValue,
                             policyOID: (d[kSecTrustSettingsPolicy as String]).flatMap(policyOID),
                             policyString: d[kSecTrustSettingsPolicyString as String] as? String)
            }
            let subject = SecCertificateCopyNormalizedSubjectSequence(c) as Data?
            let issuer = SecCertificateCopyNormalizedIssuerSequence(c) as Data?
            return TrustEntry(der: SecCertificateCopyData(c) as Data, selfSigned: subject != nil && subject == issuer, settings: settings)
        }
    }

    private static func policyOID(_ p: Any) -> String? {
        guard CFGetTypeID(p as CFTypeRef) == SecPolicyGetTypeID() else { return nil }
        return (SecPolicyCopyProperties(p as! SecPolicy) as? [String: Any])?[kSecPolicyOid as String] as? String
    }
}
