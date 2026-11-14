import Foundation
import CryptoKit
import CollieProtocol

/// One GET written to `to`, `progress(bytesSoFar, total)` as it goes (total -1 when unknown). The daemon's is
/// `AndroidDownload.fetch`; tests inject a fake.
public typealias AndroidFetch = @Sendable (_ url: URL, _ to: URL, _ progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void

/// What Collie itself downloads for Android (the cmdline-tools zip, Temurin): only from these hosts, checksummed before
/// anything is extracted. What `sdkmanager` downloads later is Google's own stack and checksums.
enum AndroidDownload {
    static let hosts: Set<String> = ["dl.google.com", "api.adoptium.net", "github.com", "objects.githubusercontent.com",
                                       "release-assets.githubusercontent.com"]
    static let repository = URL(string: "https://dl.google.com/android/repository/")!
    static let catalog = URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!
    static let temurinAPI = URL(string: "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=aarch64&image_type=jdk&os=mac&vendor=eclipse")!

    /// https on an exact listed host, default port, no credentials; on github.com only under `/adoptium/`.
    /// Checked on the first URL and on every redirect.
    static func allowed(_ u: URL) -> Bool {
        guard u.scheme?.lowercased() == "https", let host = u.host?.lowercased(), hosts.contains(host),
              u.port == nil, u.user == nil, u.password == nil else { return false }
        return host != "github.com" || (u.path.hasPrefix("/adoptium/") && !u.pathComponents.contains(".."))
    }

    /// A downloaded archive: where, how big, its checksum and the checksum's algorithm (`sha256` or `sha1`).
    struct Archive: Equatable { var url: URL, size: Int64, checksum: String, type: String }

    static func verify(_ file: URL, sha256: String) throws(ProtocolError) { try verify(file, checksum: sha256, type: "sha256") }

    /// Hashes `file` in chunks; a mismatch (or an unknown algorithm) deletes it and throws.
    static func verify(_ file: URL, checksum: String, type: String) throws(ProtocolError) {
        func fail(_ m: String) -> ProtocolError {
            try? FileManager.default.removeItem(at: file)
            return ProtocolError(code: .unavailable, message: m)
        }
        guard type == "sha256" || type == "sha1" else { throw fail("unsupported checksum type \(type)") }
        guard let h = try? FileHandle(forReadingFrom: file) else { throw fail("cannot read \(file.lastPathComponent)") }
        defer { try? h.close() }
        var s256 = SHA256(), s1 = Insecure.SHA1()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
            if type == "sha256" { s256.update(data: chunk) } else { s1.update(data: chunk) }
        }
        let got = (type == "sha256" ? Array(s256.finalize()) : Array(s1.finalize())).map { String(format: "%02x", $0) }.joined()
        guard got == checksum.lowercased() else { throw fail("checksum mismatch for \(file.lastPathComponent)") }
    }

    /// The newest stable (channel-0, not obsolete) `cmdline-tools;*` package's macOS archive in Google's
    /// `repository2-*.xml`. The catalog publishes sha1 (sha256 when present wins).
    static func cmdlineTools(catalog: Data) throws(ProtocolError) -> Archive {
        let p = CatalogParser()
        let x = XMLParser(data: catalog)
        x.delegate = p
        guard x.parse() else { throw ProtocolError(code: .unavailable, message: "the Android repository catalog is not valid XML") }
        let best = p.packages.filter { $0.path.hasPrefix("cmdline-tools;") && !$0.obsolete && ["", "channel-0"].contains($0.channel) }
            .compactMap { pkg in pkg.archives.first.map { (pkg.revision, $0) } }
            .max { $0.0.lexicographicallyPrecedes($1.0) }
        guard let a = best?.1 else { throw ProtocolError(code: .unavailable, message: "no macOS cmdline-tools in the Android repository catalog") }
        return a
    }

    /// The first asset of Adoptium's `assets/latest` answer (sha256).
    static func temurin(json: Data) throws(ProtocolError) -> Archive {
        struct Asset: Decodable { struct B: Decodable { struct P: Decodable { var link: URL, checksum: String, size: Int64 }; var package: P }; var binary: B }
        guard let p = (try? JSONDecoder().decode([Asset].self, from: json))?.first?.binary.package else {
            throw ProtocolError(code: .unavailable, message: "Adoptium answered no JDK for macOS aarch64")
        }
        return Archive(url: p.link, size: p.size, checksum: p.checksum, type: "sha256")
    }

    private final class CatalogParser: NSObject, XMLParserDelegate {
        struct Package { var path = "", obsolete = false, channel = "", revision: [Int] = [], archives: [Archive] = [] }
        private struct Draft { var url = "", size: Int64 = 0, sums: [String: String] = [:], type = "sha1", os = "", arch = "" }
        var packages: [Package] = []
        private var pkg: Package?, draft: Draft?, stack: [String] = [], text = ""

        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let e = String(e.split(separator: ":").last ?? "")
            stack.append(e); text = ""
            switch e {
            case "remotePackage": pkg = Package(path: a["path"] ?? "", obsolete: a["obsolete"] == "true")
            case "channelRef": pkg?.channel = a["ref"] ?? ""
            case "archive": draft = Draft()
            case "checksum": draft?.type = a["type"]?.lowercased() ?? "sha1"
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            let e = String(e.split(separator: ":").last ?? "")
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = stack.dropLast().suffix(2)
            switch e {
            case "major" where parent == ["remotePackage", "revision"], "minor" where parent == ["remotePackage", "revision"],
                 "micro" where parent == ["remotePackage", "revision"]: pkg?.revision.append(Int(t) ?? 0)
            case "url" where parent.last == "complete": draft?.url = t
            case "size" where parent.last == "complete": draft?.size = Int64(t) ?? 0
            case "checksum" where parent.last == "complete": if let ty = draft?.type { draft?.sums[ty] = t }
            case "host-os": draft?.os = t
            case "host-arch": draft?.arch = t
            case "archive":
                if let d = draft, ["", "macosx"].contains(d.os), ["", "aarch64", "arm64"].contains(d.arch),
                   let url = URL(string: d.url, relativeTo: AndroidDownload.repository)?.absoluteURL,
                   let (ty, sum) = d.sums["sha256"].map({ ("sha256", $0) }) ?? d.sums["sha1"].map({ ("sha1", $0) }) {
                    pkg?.archives.append(Archive(url: url, size: d.size, checksum: sum, type: ty))
                }
                draft = nil
            case "remotePackage": if let p = pkg { packages.append(p) }; pkg = nil
            default: break
            }
            stack.removeLast(); text = ""
        }
    }

    /// The daemon's fetch: an ephemeral session (no cookies, no cache), every redirect checked with `allowed`, the body
    /// streamed by URLSession to a temp file and moved to `to` only on a 200 from an allowed final URL. Cancelling the
    /// calling task cancels the download.
    static let fetch: AndroidFetch = { url, to, progress in
        guard allowed(url) else { throw ProtocolError(code: .invalidArgs, message: "download host not allowed: \(url.absoluteString)") }
        try Task.checkCancellation()
        let dl = Download(to: to, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: dl, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 60))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in dl.start(c, task) }
        } onCancel: { task.cancel() }
    }

    private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let to: URL, progress: @Sendable (Int64, Int64) -> Void, lock = NSLock()
        private var done: CheckedContinuation<Void, any Error>?, failure: (any Error)?, result: Result<Void, any Error>?
        init(to: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) { self.to = to; self.progress = progress }
        /// A cancel can complete the task before `start` stores `c`: then the stored result resumes it here.
        func start(_ c: CheckedContinuation<Void, any Error>, _ task: URLSessionDownloadTask) {
            let early = lock.withLock { () -> Result<Void, any Error>? in if result == nil { done = c }; return result }
            if let early { c.resume(with: early) } else { task.resume() }
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
            newRequest.url.map(AndroidDownload.allowed) == true ? newRequest : nil
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
            progress(w, t)
        }
        /// The temp file is gone once this returns: move it now (or record why not).
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo tmp: URL) {
            let http = downloadTask.response as? HTTPURLResponse
            let err: (any Error)?
            if http?.statusCode != 200 || !(http?.url.map(AndroidDownload.allowed) ?? false) {
                err = ProtocolError(code: .unavailable, message: "download answered \(http?.statusCode ?? 0) from \(http?.url?.host ?? "?")")
            } else {
                do { try FileManager.default.moveItem(at: tmp, to: to); err = nil } catch { err = error }
            }
            lock.withLock { failure = err }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: (any Error)?) {
            let r: Result<Void, any Error> = lock.withLock { (e ?? failure).map { .failure($0) } ?? .success(()) }
            let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                defer { done = nil }
                if done == nil { result = r }
                return done
            }
            c?.resume(with: r)
        }
    }
}
