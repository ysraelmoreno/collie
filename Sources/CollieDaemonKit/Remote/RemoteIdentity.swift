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

    /// The identity in `dir`, made on first use.
    static func loadOrCreate(dir: URL) throws -> RemoteIdentity {
        if let id = try? load(dir: dir) { return id }
        try create(dir: dir)
        return try load(dir: dir)
    }

    /// A new key and certificate: every paired phone's pin breaks, so `devices` are all revoked (they pair again).
    static func rotate(dir: URL, devices: RemoteDevices? = nil) throws -> RemoteIdentity {
        try create(dir: dir)
        try devices?.revokeAll()
        return try load(dir: dir)
    }

    private static func p12(_ dir: URL) -> URL { dir.appendingPathComponent("identity.p12") }
    private static func pass(_ dir: URL) -> URL { dir.appendingPathComponent("identity.pass") }

    static func load(dir: URL) throws -> RemoteIdentity {
        let data = try Data(contentsOf: p12(dir)), pw = try String(contentsOf: pass(dir), encoding: .utf8)
        var items: CFArray?
        let opts = [kSecImportExportPassphrase: pw, kSecImportToMemoryOnly: true] as [CFString: Any] as CFDictionary
        let st = SecPKCS12Import(data as CFData, opts, &items)
        guard st == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let any = first[kSecImportItemIdentity as String] else {
            throw ProtocolError(code: .internal, message: "remote identity unreadable (\(st))")
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
    private static func create(dir: URL) throws {
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
        try openssl(["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                     // named curve: LibreSSL writes explicit curve parameters by default, and Apple's TLS then fails every
                     // handshake with -9810 (errSSLInternal) although the key itself signs
                     "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-sha256",
                     "-days", "3650", "-subj", "/CN=Collie", "-keyout", key.path, "-out", cert.path])
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", out.path, "-passout", "file:\(passFile.path)"])
        chmod(out.path, 0o600)
        // the pass first: a crash between the renames leaves a pair that fails to load, and loadOrCreate makes a new one
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
