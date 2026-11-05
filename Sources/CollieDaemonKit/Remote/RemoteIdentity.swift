import Foundation
import Security
import CryptoKit
import CollieProtocol

/// The remote listener's TLS identity (remote API spec §1): a self-signed P-256 certificate whose SHA-256 the phone
/// pins at pairing. Kept as `identity.p12` + `identity.pass` (0600) in `<root>/remote/` (0700), loaded in memory only
/// (`kSecImportToMemoryOnly`, never the Keychain).
// ponytail: /usr/bin/openssl (LibreSSL, part of macOS) makes the cert and the PKCS#12. CryptoKit can sign a hand-built
// X.509, but a SecIdentity still needs a PKCS#12 (or the Keychain), and writing PKCS#12's PBE by hand is more code
// than this. Key at rest in a 0600 file (decision D6); upgrade path: the login Keychain with an ACL for collied.
final class RemoteIdentity: @unchecked Sendable {   // immutable after init
    let identity: SecIdentity
    /// base64url (no padding) SHA-256 of the certificate's DER: what the QR carries and the phone pins.
    let fingerprint: String

    private init(identity: SecIdentity, fingerprint: String) { self.identity = identity; self.fingerprint = fingerprint }

    static func fingerprint(der: Data) -> String {
        Data(SHA256.hash(data: der)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The identity in `dir`, made on first use only. One that exists but doesn't load is an error, never replaced:
    /// a new identity breaks every phone's pin, which only Trocar certificado (`rotate`) may do.
    static func loadOrCreate(dir: URL) throws -> RemoteIdentity {
        let fm = FileManager.default
        if fm.fileExists(atPath: p12(dir).path) || fm.fileExists(atPath: pass(dir).path) {
            do { return try load(dir: dir) } catch let e as ProtocolError {
                throw ProtocolError(code: e.code, message: e.message + " — use Trocar certificado para gerar outra")
            }
        }
        try create(dir: dir)
        return try load(dir: dir)
    }

    /// A new key and certificate: every paired phone's pin breaks, so `devices` are all revoked (they pair again).
    static func rotate(dir: URL, devices: RemoteDevices? = nil, key: P256.Signing.PrivateKey = usableKey()) throws -> RemoteIdentity {
        try create(dir: dir, key: key)
        try devices?.revokeAll()
        return try load(dir: dir)
    }

    private static func p12(_ dir: URL) -> URL { dir.appendingPathComponent("identity.p12") }
    private static func pass(_ dir: URL) -> URL { dir.appendingPathComponent("identity.pass") }

    static func load(dir: URL) throws -> RemoteIdentity {
        let data = try Data(contentsOf: p12(dir)), pw = try String(contentsOf: pass(dir), encoding: .utf8)
        let opts = [kSecImportExportPassphrase: pw, kSecImportToMemoryOnly: true] as [CFString: Any] as CFDictionary
        var items: CFArray?
        let st = SecPKCS12Import(data as CFData, opts, &items)
        let all = items as? [[String: Any]] ?? []
        guard st == errSecSuccess, let any = all.first?[kSecImportItemIdentity as String] else {
            // status 0 with no item: the key bag was dropped (e.g. a 31-byte EC key, see `usableKey`)
            let certs = all.first?[kSecImportItemCertChain as String].map { ($0 as? [Any])?.count ?? -1 } ?? 0
            throw ProtocolError(code: .internal, message: "remote identity unreadable (status \(st), items \(all.count), "
                                + "certs \(certs), p12 \(data.count) bytes, pass \(pw.count) chars)")
        }
        let identity = any as! SecIdentity   // CF type: the cast can't fail once present
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw ProtocolError(code: .internal, message: "remote identity has no certificate")
        }
        return RemoteIdentity(identity: identity, fingerprint: fingerprint(der: SecCertificateCopyData(cert) as Data))
    }

    /// Writes a new identity into `dir`: made in a 0700 scratch dir inside it (the PEM key never sits elsewhere), then
    /// renamed into place; the scratch dir is always removed.
    /// A P-256 key whose scalar doesn't start with 0x00. LibreSSL writes such a key (1 in 256) into the PKCS#12 as a
    /// 31-byte private key (RFC 5915 wants 32), and SecPKCS12Import then drops it without an error (status 0, no
    /// item): the identity never loads. Seen as flaky remote suites on 2026-11-05; the next key is drawn instead.
    static func usableKey(_ next: () -> P256.Signing.PrivateKey = { P256.Signing.PrivateKey() }) -> P256.Signing.PrivateKey {
        while true { let k = next(); if k.rawRepresentation.first != 0 { return k } }
    }

    private static func create(dir: URL, key k: P256.Signing.PrivateKey = usableKey()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let tmp = dir.appendingPathComponent(".new-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmp) }
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else {
            throw ProtocolError(code: .internal, message: "no randomness for the remote identity")
        }
        let pw = Data(raw).base64EncodedString()
        let passFile = tmp.appendingPathComponent("pass"), key = tmp.appendingPathComponent("key.pem")
        let cert = tmp.appendingPathComponent("cert.pem"), out = tmp.appendingPathComponent("id.p12")
        try Data(pw.utf8).write(to: passFile)
        chmod(passFile.path, 0o600)
        // the key is ours (CryptoKit, PKCS#8 with the named curve: LibreSSL's own `-newkey ec` writes explicit curve
        // parameters, which make Apple's TLS fail every handshake with -9810); openssl only signs the certificate
        guard FileManager.default.createFile(atPath: key.path, contents: Data(k.pemRepresentation.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ProtocolError(code: .internal, message: "remote identity: cannot write the key")
        }
        try openssl(["req", "-x509", "-new", "-key", key.path, "-sha256", "-days", "3650", "-subj", "/CN=Collie", "-out", cert.path])
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", out.path, "-passout", "file:\(passFile.path)"])
        chmod(out.path, 0o600)
        // the pass first: a crash between the renames leaves a pair that fails to load (reported; Trocar certificado fixes it)
        guard rename(passFile.path, pass(dir).path) == 0, rename(out.path, p12(dir).path) == 0 else {
            throw ProtocolError(code: .internal, message: "remote identity: rename failed (\(errno))")
        }
    }

    private static func openssl(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        let err = Pipe(); p.standardError = err
        try p.run()
        let msg = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ProtocolError(code: .internal, message: "openssl \(args[0]) failed: \(String(decoding: msg.suffix(300), as: UTF8.self))")
        }
    }
}
