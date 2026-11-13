import Testing
import Foundation
@testable import CollieDaemonKit

@Suite struct ZipWriterTests {
    private func unzip(_ args: [String]) throws -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    private func tempZip(_ entries: [(name: String, data: Data)]) throws -> String {
        let path = NSTemporaryDirectory() + "zipwriter-\(UUID().uuidString).zip"
        try ZipWriter.archive(entries).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func crcMatchesKnownVector() {
        #expect(ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF43926)
    }

    @Test func archiveReadsBackWithUnzip() throws {
        let bin = Data((0...255).map { UInt8($0) })
        let path = try tempZip([("a.txt", Data("hello".utf8)), ("dir/b.bin", bin)])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try unzip(["-t", path]).0 == 0)
        let (code, bytes) = try unzip(["-p", path, "dir/b.bin"])
        #expect(code == 0 && bytes == bin)
    }

    @Test func tooManyEntriesThrows() {
        let entries = (0..<70_000).map { (name: "f\($0)", data: Data()) }
        #expect(throws: ZipError.tooLarge) { try ZipWriter.archive(entries) }
    }

    @Test func emptyDataEntry() throws {
        let path = try tempZip([("empty.txt", Data())])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try unzip(["-t", path]).0 == 0)
    }
}
