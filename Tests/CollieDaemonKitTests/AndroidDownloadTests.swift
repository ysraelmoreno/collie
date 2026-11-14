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
                  "https://DL.google.com/x"]
        for s in ok { #expect(AndroidDownload.allowed(URL(string: s)!), "\(s)") }
        let bad = ["http://dl.google.com/x", "https://dl.google.com:8443/x", "https://u:p@dl.google.com/x",
                   "https://u@dl.google.com/x", "https://dl.google.com.evil.com/x", "https://evil-dl.google.com/x",
                   "https://github.com/evil/repo", "https://github.com/adoptium/../evil/x", "https://github.com/adoptiumx/x",
                   "ftp://dl.google.com/x", "file:///etc/passwd"]
        for s in bad { #expect(!AndroidDownload.allowed(URL(string: s)!), "\(s)") }
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
        #expect(a.url.absoluteString == "https://dl.google.com/android/repository/commandlinetools-mac-19_latest.zip")
        #expect(a.size == 164 && a.checksum == "cc" && a.type == "sha1")
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
