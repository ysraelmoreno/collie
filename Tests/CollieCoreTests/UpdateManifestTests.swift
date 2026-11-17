import Foundation
import Testing
import CollieCore

struct UpdateManifestTests {
    static let sha = String(repeating: "ab", count: 32)
    static func json(_ over: [String: Any] = [:], drop: String? = nil) -> Data {
        var o: [String: Any] = [
            "format": 1, "version": "0.2.0", "tag": "v0.2.0", "dmg": "Collie-0.2.0.dmg", "size": 41_711_021,
            "sha256": sha, "minimumSystemVersion": "15.0", "teamId": "AG8JQAH6YB", "figcraftEngine": "0.7.0-c1",
            "page": "https://github.com/ysraelmoreno/collie/releases/tag/v0.2.0",
        ]
        for (k, v) in over { o[k] = v }
        if let drop { o[drop] = nil }
        return try! JSONSerialization.data(withJSONObject: o)
    }
    static let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)

    @Test func decodesValid() throws {
        let m = try UpdateManifest.decode(Self.json())
        #expect(m.version == "0.2.0" && m.tag == "v0.2.0" && m.size == 41_711_021 && m.sha256 == Self.sha)
        #expect(m.requiresServiceRestart == nil)
    }

    @Test func refusesOversize() {
        var d = Self.json()
        d.append(Data(repeating: 0x20, count: 65_537 - d.count))
        #expect(d.count == 65_537)
        #expect(throws: (any Error).self) { try UpdateManifest.decode(d) }
    }

    @Test func refusesMissingField() {
        for k in ["format", "version", "tag", "dmg", "size", "sha256", "minimumSystemVersion", "teamId", "figcraftEngine", "page"] {
            #expect(throws: (any Error).self, "\(k)") { try UpdateManifest.decode(Self.json(drop: k)) }
        }
    }

    @Test func refusesWrongFormat() {
        #expect(throws: (any Error).self) { try UpdateManifest.decode(Self.json(["format": 2])) }
    }

    @Test func refusesBadSha() {
        for s in [String(repeating: "AB", count: 32), String(repeating: "a", count: 63), String(repeating: "g", count: 64)] {
            #expect(throws: (any Error).self) { try UpdateManifest.decode(Self.json(["sha256": s])) }
        }
    }

    @Test func refusesBadTag() {
        for t in ["0.2.0", "v0.2", "v0.2.0-beta", "figcraft-v0.7.0-c1"] {
            #expect(throws: (any Error).self, "\(t)") { try UpdateManifest.decode(Self.json(["tag": t])) }
        }
    }

    @Test func refusesTagVersionMismatch() {
        #expect(throws: (any Error).self) {
            try UpdateManifest.decode(Self.json(["tag": "v0.2.1", "page": "https://github.com/ysraelmoreno/collie/releases/tag/v0.2.1"]))
        }
    }

    @Test func refusesDmgNameMismatch() {
        for n in ["Collie-0.2.1.dmg", "Collie.dmg", "../Collie-0.2.0.dmg"] {
            #expect(throws: (any Error).self, "\(n)") { try UpdateManifest.decode(Self.json(["dmg": n])) }
        }
    }

    @Test func refusesForeignPage() {
        for p in ["https://evil.example/releases/tag/v0.2.0", "https://github.com/ysraelmoreno/collie/releases/tag/v0.1.0"] {
            #expect(throws: (any Error).self, "\(p)") { try UpdateManifest.decode(Self.json(["page": p])) }
        }
    }

    @Test func refusesSizeOutOfRange() {
        for s in [0, 500_000_001] {
            #expect(throws: (any Error).self, "\(s)") { try UpdateManifest.decode(Self.json(["size": s])) }
        }
        #expect((try? UpdateManifest.decode(Self.json(["size": 500_000_000]))) != nil)
    }

    @Test func dmgURLIsDerived() throws {
        let m = try UpdateManifest.decode(Self.json())
        #expect(m.dmgURL.absoluteString == "https://github.com/ysraelmoreno/collie/releases/download/v0.2.0/Collie-0.2.0.dmg")
    }

    @Test func versionOrder() {
        #expect(AppVersion("0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        #expect(AppVersion("v0.2.0") == AppVersion("0.2.0"))
        #expect(AppVersion("0.1") == nil)
        #expect(AppVersion("0.1.0-beta") == nil)
        #expect(AppVersion("0.-1.0") == nil)
        #expect(AppVersion("0.2.0")!.description == "0.2.0")
    }

    @Test func offerRefusesDowngradeAndEqual() throws {
        let m = try UpdateManifest.decode(Self.json())
        #expect(m.offer(installed: "0.1.1", system: Self.sequoia, skipped: nil))
        #expect(!m.offer(installed: "0.2.0", system: Self.sequoia, skipped: nil))
        #expect(!m.offer(installed: "0.3.0", system: Self.sequoia, skipped: nil))
        #expect(!m.offer(installed: "dev", system: Self.sequoia, skipped: nil))
    }

    @Test func offerRespectsSkipped() throws {
        let m = try UpdateManifest.decode(Self.json())
        #expect(!m.offer(installed: "0.1.1", system: Self.sequoia, skipped: "0.2.0"))
        #expect(m.offer(installed: "0.1.1", system: Self.sequoia, skipped: "0.1.9"))
    }

    @Test func offerRespectsMinimumSystem() throws {
        let m = try UpdateManifest.decode(Self.json(["minimumSystemVersion": "15.2"]))
        #expect(!m.offer(installed: "0.1.1", system: Self.sequoia, skipped: nil))
        #expect(m.offer(installed: "0.1.1", system: OperatingSystemVersion(majorVersion: 15, minorVersion: 2, patchVersion: 0), skipped: nil))
        #expect(m.offer(installed: "0.1.1", system: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0), skipped: nil))
    }

    @Test func ignoresUnknownExtraField() throws {
        let m = try UpdateManifest.decode(Self.json(["future": "x", "requiresServiceRestart": true]))
        #expect(m.requiresServiceRestart == true)
    }
}
