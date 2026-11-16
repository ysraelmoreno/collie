import Testing
import Foundation
@testable import CollieDaemonKit

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// The pin's `inputs` is what `scripts/figcraft-inputs.sh` prints (figcraft.yml refuses to build otherwise).
@Suite struct FigcraftPinInputsTests {
    @Test func pinInputsMatchScript() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [repoRoot.appendingPathComponent("scripts/figcraft-inputs.sh").path]
        p.currentDirectoryURL = repoRoot
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let printed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(printed.count == 64)
        let pin = try #require(FigcraftPin.load(repoRoot.appendingPathComponent("Resources/figcraft-engine.json")))
        #expect(pin.inputs == printed)
    }
}
