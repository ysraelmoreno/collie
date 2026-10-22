import Foundation
import Testing
@testable import CollieTerminal

@Suite struct ScrollbackBufferTests {
    @Test func stripsAnsi() {
        #expect(ANSI.strip("\u{1B}[31mred\u{1B}[0m \u{1B}]0;title\u{07}ok") == "red ok")
    }

    @Test func tailReturnsLastLines() {
        let b = ScrollbackBuffer(spillURL: nil)
        b.append(Data("l1\nl2\nl3\nl4\nl5".utf8))
        let r = b.tail(lines: 2)
        #expect(r.text == "l4\nl5")
        #expect(r.truncated == false)
    }

    @Test func capsMemoryUnderFlood() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collie-sb-\(UUID().uuidString)/spill.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let b = ScrollbackBuffer(memoryCapBytes: 65_536, spillURL: url)
        let block = Data(repeating: 0x61, count: 4096)
        for _ in 0..<2560 { b.append(block) }
        #expect(b.memoryBytes <= 65_536)
        #expect(b.totalBytesWritten == 10_485_760)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 10_485_760)
    }

    @Test func spillStopsAtCap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collie-sb-\(UUID().uuidString)/spill.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let b = ScrollbackBuffer(memoryCapBytes: 1024, spillURL: url, spillCapBytes: 10_000)
        for _ in 0..<10 { b.append(Data(repeating: 0x61, count: 4096)) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 10_000)
        #expect(b.totalBytesWritten == 40_960 && b.memoryBytes <= 1024)
        #expect(b.text(since: 0).truncated && b.tail(lines: 10).truncated)
        b.closeSpill(deleting: true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func textSinceMarkTruncatesWhenEvicted() {
        let b = ScrollbackBuffer(memoryCapBytes: 1024, spillURL: nil)
        let m = b.mark()
        b.append(Data(repeating: 0x62, count: 4096))
        #expect(b.text(since: m).truncated == true)
        let m2 = b.mark()
        let hundred = String(repeating: "c", count: 100)
        b.append(Data(hundred.utf8))
        let r = b.text(since: m2)
        #expect(r.truncated == false)
        #expect(r.text == hundred)
    }
}
