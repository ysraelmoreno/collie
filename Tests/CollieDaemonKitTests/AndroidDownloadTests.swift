import Testing
import Foundation
import CryptoKit
import CollieProtocol
@testable import CollieDaemonKit

func androidHex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }

@Suite struct AndroidDownloadTests {
    @Test func allowedHostsOnlyHttps() {
        let ok = ["https://dl.google.com/android/repository/repository2-3.xml",
                  "https://api.adoptium.net/v3/assets/latest/21/hotspot",
                  "https://github.com/adoptium/temurin21-binaries/releases/download/x/j.tar.gz",
                  "https://objects.githubusercontent.com/github-production-release-asset/1",
                  "https://release-assets.githubusercontent.com/github-production-release-asset/1?sp=r",
                  "https://DL.google.com/x"]
        for s in ok { #expect(AndroidDownload.allowed(URL(string: s)!), "\(s)") }
        let bad = ["http://dl.google.com/x", "https://dl.google.com:8443/x", "https://u:p@dl.google.com/x",
                   "https://u@dl.google.com/x", "https://dl.google.com.evil.com/x", "https://evil-dl.google.com/x",
                   "https://github.com/evil/repo", "https://github.com/adoptium/../evil/x", "https://github.com/adoptiumx/x",
                   "https://evil.release-assets.githubusercontent.com/x", "https://release-assets.githubusercontent.com:444/x",
                   "ftp://dl.google.com/x", "file:///etc/passwd"]
        for s in bad { #expect(!AndroidDownload.allowed(URL(string: s)!), "\(s)") }
    }

    @Test func allowsFigcraftReleasePath() {
        #expect(AndroidDownload.allowed(URL(string:
            "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v0.7.0-c1/figcraft-0.7.0-c1-arm64.tar.gz")!))
    }
    @Test func allowsCollieLatestDownload() {
        #expect(AndroidDownload.allowed(URL(string: "https://github.com/ysraelmoreno/collie/releases/latest/download/update.json")!))
    }
    @Test func allowsCollieVersionedDownload() {
        #expect(AndroidDownload.allowed(URL(string: "https://github.com/ysraelmoreno/collie/releases/download/v0.2.0/Collie-0.2.0.dmg")!))
        #expect(AndroidDownload.allowed(URL(string: "https://github.com/ysraelmoreno/collie/releases/download/v0.1.0/Collie.dmg")!))
    }
    @Test func stillAllowsFigcraft() {
        #expect(AndroidDownload.allowed(URL(string:
            "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v0.7.0-c1/figcraft-0.7.0-c1-arm64.tar.gz")!))
    }
    @Test func refusesOtherCollieReleasePaths() {
        for s in ["https://github.com/ysraelmoreno/collie/releases/download/x0.1.0/Collie.dmg",
                  "https://github.com/ysraelmoreno/collie/releases/download/v0.2.0/../../../evil/x",
                  "https://github.com/ysraelmoreno/collie/releases/latest/download/../../evil",
                  "https://github.com/ysraelmoreno/collie/releases/latest/x",
                  "https://github.com/ysraelmoreno/collie/archive/figcraft-v1.tar.gz",
                  "https://github.com/ysraelmoreno/other/releases/download/figcraft-v1/x"] {
            #expect(!AndroidDownload.allowed(URL(string: s)!), "\(s)")
        }
    }
    @Test func allowsPluginCatalogPaths() {
        #expect(AndroidDownload.allowed(URL(string: "https://github.com/ysraelmoreno/collie/releases/download/plugin-vizinho-v0.1.0/vizinho-0.1.0.tar.gz")!))
        #expect(AndroidDownload.allowed(URL(string: "https://github.com/ysraelmoreno/collie/releases/download/plugins-catalog/plugins.json")!))
        for s in ["https://github.com/ysraelmoreno/collie/releases/download/plugins-catalogX/plugins.json",
                  "https://github.com/ysraelmoreno/collie/releases/download/pluginx-1/x",
                  "https://github.com/ysraelmoreno/collie/releases/download/plugin-x/../../../evil/x",
                  "https://github.com/ysraelmoreno/other/releases/download/plugin-x/x"] {
            #expect(!AndroidDownload.allowed(URL(string: s)!), "\(s)")
        }
    }
    @Test func refusesDotDotInFigcraftPath() {
        #expect(!AndroidDownload.allowed(URL(string:
            "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v1/../../../evil/x")!))
    }

    @Test func verifyRejectsABadChecksumAndDeletesTheFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("collie-verify-\(UUID().uuidString)")
        let data = Data("hello android".utf8)
        try data.write(to: f)
        try AndroidDownload.verify(f, sha256: androidHex(SHA256.hash(data: data)).uppercased())
        try AndroidDownload.verify(f, checksum: androidHex(Insecure.SHA1.hash(data: data)), type: "sha1")
        #expect(FileManager.default.fileExists(atPath: f.path))
        #expect(throws: ProtocolError.self) { try AndroidDownload.verify(f, sha256: String(repeating: "0", count: 64)) }
        #expect(!FileManager.default.fileExists(atPath: f.path))
        try data.write(to: f)
        #expect(throws: ProtocolError.self) { try AndroidDownload.verify(f, checksum: "abc", type: "md5") }
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func catalogPicksTheNewestStableMacCmdlineTools() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03">
          <channel id="channel-0">stable</channel>
          <remotePackage path="cmdline-tools;9.0">
            <revision><major>9</major><minor>0</minor></revision>
            <channelRef ref="channel-0"/>
            <archives><archive><complete><size>100</size><checksum type="sha1">aa</checksum><url>old-mac.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;19.0">
            <revision><major>19</major><minor>0</minor></revision>
            <dependencies><dependency path="x"><min-revision><major>99</major></min-revision></dependency></dependencies>
            <channelRef ref="channel-0"/>
            <archives>
              <archive><complete><size>1</size><checksum type="sha1">bb</checksum><url>linux.zip</url></complete><host-os>linux</host-os></archive>
              <archive><complete><size>164</size><checksum type="sha1">cc</checksum><url>commandlinetools-mac-19_latest.zip</url></complete><host-os>macosx</host-os></archive>
            </archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;20.0">
            <revision><major>20</major><minor>0</minor></revision>
            <channelRef ref="channel-0"/>
            <archives><archive><complete><size>7</size><checksum type="sha1">zz</checksum><url>commandlinetools-mac-20_latest.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;23.0">
            <revision><major>23</major><minor>0</minor></revision>
            <channelRef ref="channel-0"/>
            <archives><archive><complete><size>7</size><checksum type="sha1">zz</checksum><url>mac-23.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;latest">
            <revision><major>23</major><minor>0</minor></revision>
            <channelRef ref="channel-0"/>
            <archives><archive><complete><size>7</size><checksum type="sha1">zz</checksum><url>mac-latest.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;19.0-alpha01">
            <revision><major>19</major><minor>0</minor><preview>1</preview></revision>
            <channelRef ref="channel-3"/>
            <archives><archive><complete><size>7</size><checksum type="sha1">zz</checksum><url>mac-alpha.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;20.0-alpha01">
            <revision><major>20</major><minor>0</minor><preview>1</preview></revision>
            <channelRef ref="channel-3"/>
            <archives><archive><complete><size>1</size><checksum type="sha1">dd</checksum><url>preview-mac.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="cmdline-tools;30.0" obsolete="true">
            <revision><major>30</major></revision>
            <channelRef ref="channel-0"/>
            <archives><archive><complete><size>1</size><checksum type="sha1">ee</checksum><url>obsolete-mac.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
          <remotePackage path="platform-tools">
            <revision><major>40</major></revision>
            <archives><archive><complete><size>1</size><checksum type="sha1">ff</checksum><url>pt-mac.zip</url></complete><host-os>macosx</host-os></archive></archives>
          </remotePackage>
        </sdk:sdk-repository>
        """
        let a = try AndroidDownload.cmdlineTools(catalog: Data(xml.utf8))
        #expect(a.url.absoluteString == "https://dl.google.com/android/repository/commandlinetools-mac-20_latest.zip")
        #expect(a.size == 7 && a.checksum == "zz" && a.type == "sha1")
        #expect(throws: ProtocolError.self) { try AndroidDownload.cmdlineTools(catalog: Data("<sdk-repository/>".utf8)) }
    }

    @Test func temurinParsesTheAdoptiumAnswer() throws {
        let json = """
        [{"binary":{"architecture":"aarch64","os":"mac","package":{"checksum":"ABC123","link":"https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.5_11.tar.gz","name":"OpenJDK21U.tar.gz","size":200}},"version":{"semver":"21.0.5+11"}}]
        """
        let a = try AndroidDownload.temurin(json: Data(json.utf8))
        #expect(a.url.host == "github.com" && a.url.path.hasPrefix("/adoptium/"))
        #expect(a.size == 200 && a.checksum == "ABC123" && a.type == "sha256")
        #expect(throws: ProtocolError.self) { try AndroidDownload.temurin(json: Data("[]".utf8)) }
    }
}

/// Serves canned responses by URL, in-process (no network); requests seen are kept for assertions.
final class FetchStub: URLProtocol, @unchecked Sendable {
    struct Canned { var status = 200; var headers: [String: String] = [:]; var chunks: [Data] }
    nonisolated(unsafe) static var canned: [String: Canned] = [:]
    nonisolated(unsafe) static var seen: [String: URLRequest] = [:]
    static let lock = NSLock()
    static func serve(_ url: URL, _ c: Canned) { lock.withLock { canned[url.absoluteString] = c } }
    static func request(_ url: URL) -> URLRequest? { lock.withLock { seen[url.absoluteString] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let c = Self.lock.withLock { () -> Canned? in Self.seen[url.absoluteString] = request; return Self.canned[url.absoluteString] }
        guard let c else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let r = HTTPURLResponse(url: url, statusCode: c.status, httpVersion: "HTTP/1.1", headerFields: c.headers)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        for d in c.chunks { client?.urlProtocol(self, didLoad: d) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FetchStub.self]
        return c
    }
}

struct AndroidFetchLimitTests {
    static func dest() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("fetch-\(UUID().uuidString)") }
    static let ua = ["User-Agent": "Collie/0.2.0"]

    @Test func fetchesWithinLimit() async throws {
        let url = URL(string: "https://github.com/ysraelmoreno/collie/releases/latest/download/update.json?t=ok")!
        FetchStub.serve(url, .init(chunks: [Data(repeating: 1, count: 1000)]))
        let to = Self.dest(); defer { try? FileManager.default.removeItem(at: to) }
        try await AndroidDownload.fetch(url, to: to, limit: 65_536, headers: Self.ua, configuration: FetchStub.configuration) { _, _ in }
        #expect(try Data(contentsOf: to).count == 1000)
    }

    @Test func limitCancels() async {
        let url = URL(string: "https://github.com/ysraelmoreno/collie/releases/latest/download/update.json?t=big")!
        FetchStub.serve(url, .init(chunks: [Data(repeating: 1, count: 40_000), Data(repeating: 1, count: 30_000)]))
        let to = Self.dest(); defer { try? FileManager.default.removeItem(at: to) }
        await #expect(throws: ProtocolError.self) {
            try await AndroidDownload.fetch(url, to: to, limit: 65_536, headers: Self.ua, configuration: FetchStub.configuration) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: to.path))
    }

    @Test func limitByContentLength() async {
        let url = URL(string: "https://github.com/ysraelmoreno/collie/releases/latest/download/update.json?t=len")!
        FetchStub.serve(url, .init(headers: ["Content-Length": "70000"], chunks: [Data(repeating: 1, count: 100)]))
        let to = Self.dest(); defer { try? FileManager.default.removeItem(at: to) }
        do {
            try await AndroidDownload.fetch(url, to: to, limit: 65_536, headers: Self.ua, configuration: FetchStub.configuration) { _, _ in }
            Issue.record("expected a refusal")
        } catch let e as ProtocolError {
            #expect(e.message == AndroidDownload.tooLarge)
        } catch { Issue.record("unexpected \(error)") }
        #expect(!FileManager.default.fileExists(atPath: to.path))
    }

    @Test func sendsUserAgent() async throws {
        let url = URL(string: "https://github.com/ysraelmoreno/collie/releases/latest/download/update.json?t=ua")!
        FetchStub.serve(url, .init(chunks: [Data("{}".utf8)]))
        let to = Self.dest(); defer { try? FileManager.default.removeItem(at: to) }
        try await AndroidDownload.fetch(url, to: to, limit: 65_536, headers: Self.ua, configuration: FetchStub.configuration) { _, _ in }
        #expect(FetchStub.request(url)?.value(forHTTPHeaderField: "User-Agent") == "Collie/0.2.0")
    }

    @Test func noCacheWithHeaders() {
        let c = AndroidDownload.sessionConfiguration(.ephemeral, headers: Self.ua)
        #expect(c.urlCache == nil)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(AndroidDownload.sessionConfiguration(.ephemeral, headers: [:]).urlCache != nil)   // the Android path as it was
    }

    @Test func refusesDisallowedHostBeforeFetching() async {
        let url = URL(string: "https://example.com/update.json")!
        await #expect(throws: ProtocolError.self) {
            try await AndroidDownload.fetch(url, to: Self.dest(), limit: 65_536, headers: Self.ua, configuration: FetchStub.configuration) { _, _ in }
        }
        #expect(FetchStub.request(url) == nil)
    }
}
