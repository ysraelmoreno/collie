import Foundation
import CryptoKit

/// Identity of an executable build: first 16 hex of the SHA-256 of the file. The daemon reports the one it started
/// from; the app compares it with its bundled collied to notice a stale service after an update.
public enum BuildID {
    /// Blocking file read: call off the cooperative pool. nil when the file cannot be read.
    public static func of(_ file: URL) -> String? {
        guard let d = try? Data(contentsOf: file.resolvingSymlinksInPath(), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
