import Crypto
import Foundation
import SwiftASN1

/// OpenSSL `X509_NAME_hash_old`: MD5 of the subject Name's DER, first 4 bytes read little-endian, printed `%08x`.
/// Android names system CA files `<this>.0`.
/// Reads only the subject's bytes from the TBSCertificate: swift-certificates' full parse rejects real roots
/// (negative serial numbers: "INTEGER encoded with top bit set"), and the hash must match OpenSSL byte for byte.
func subjectHashOld(der: [UInt8]) throws -> String {
    let cert = try DER.parse(der)
    guard case .constructed(let top) = cert.content, let tbs = Array(top).first,
          case .constructed(let fields) = tbs.content else { throw ASN1Error.invalidASN1Object(reason: "not a certificate") }
    var f = Array(fields)
    if f.first?.identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) { f.removeFirst() }   // [0] version
    guard f.count > 4 else { throw ASN1Error.invalidASN1Object(reason: "short TBSCertificate") }
    let subject = f[4]   // serial, signature, issuer, validity, subject
    let d = Array(Insecure.MD5.hash(data: Array(subject.encodedBytes)))
    let v = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    return String(format: "%08x", v)
}

/// The first certificate in a PEM file (Android's cacerts files carry `openssl x509 -text` around it), else the file as DER.
func certificateDER(_ data: Data) -> [UInt8]? {
    guard let text = String(data: data, encoding: .utf8),
          let r = text.range(of: "-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----", options: .regularExpression) else { return Array(data) }
    let body = text[r].split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    return Data(base64Encoded: body).map(Array.init)
}

// usage: spike-hash <cert.pem|cert.der>...  → "<hash> <path>" per file; failures go to stderr, exit 1
var failed = false
for path in CommandLine.arguments.dropFirst() {
    do {
        guard let der = certificateDER(try Data(contentsOf: URL(fileURLWithPath: path))) else { throw ASN1Error.invalidPEMDocument(reason: "bad base64") }
        print("\(try subjectHashOld(der: der)) \(path)")
    } catch {
        FileHandle.standardError.write("FAIL \(path): \(error)\n".data(using: .utf8)!); failed = true
    }
}
exit(failed ? 1 : 0)
