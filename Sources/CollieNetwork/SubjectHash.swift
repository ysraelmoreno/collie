import CryptoKit
import Foundation

/// OpenSSL `X509_NAME_hash_old`: Android names system CA files `<hash>.0`.
public enum SubjectHash {
    /// MD5 of the subject Name's DER (full TLV), first 4 bytes read little-endian, `%08x`.
    public static func old(derSubject: Data) -> String {
        let d = Array(Insecure.MD5.hash(data: derSubject))
        let v = UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
        return String(format: "%08x", v)
    }

    /// The subject Name's DER bytes from a DER certificate. Walks the TLVs by hand: full X.509 parsers reject
    /// real roots (e.g. negative serials) and the hash must match OpenSSL byte for byte.
    public static func subject(certificateDER der: Data) -> Data? {
        let b = Array(der)
        guard let cert = tlv(b, 0), b[0] == 0x30, let tbs = tlv(b, cert.content), b[cert.content] == 0x30 else { return nil }
        var at = tbs.content
        if b[at] == 0xA0, let v = tlv(b, at) { at = v.end }   // [0] version
        for _ in 0..<4 { guard let f = tlv(b, at) else { return nil }; at = f.end }   // serial, signature, issuer, validity
        guard let s = tlv(b, at), s.end <= tbs.end else { return nil }
        return Data(b[at..<s.end])
    }

    /// One DER TLV at `at`: where its content starts and where it ends.
    private static func tlv(_ b: [UInt8], _ at: Int) -> (content: Int, end: Int)? {
        guard at + 1 < b.count else { return nil }
        var i = at + 2, len = Int(b[at + 1])
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard (1...4).contains(n), i + n <= b.count else { return nil }
            len = b[i..<i + n].reduce(0) { $0 << 8 | Int($1) }
            i += n
        }
        return i + len <= b.count ? (i, i + len) : nil
    }
}
