import Foundation
import Testing
import CollieCore

struct CodeSignatureTests {
    static func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("codesig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func requirementText() {
        // the exact requirement FigcraftInstaller checked before it delegated here
        #expect(CodeSignature.requirement(identifier: "figcraft-server", teamId: "AG8JQAH6YB") ==
            "identifier \"figcraft-server\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"AG8JQAH6YB\"")
    }

    @Test func dmgRequirementText() {
        #expect(CodeSignature.dmgRequirement(teamId: "AG8JQAH6YB") ==
            "anchor apple generic and certificate leaf[subject.OU] = \"AG8JQAH6YB\" and notarized")
    }

    @Test func teamConstant() { #expect(CodeSignature.team == "AG8JQAH6YB") }

    @Test func unsignedIsRefused() throws {
        let d = try Self.temp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("tool")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        #expect(!CodeSignature.signedByTeam(f, identifier: "tool", teamId: CodeSignature.team))
    }

    @Test func appleSignedIsNotTeam() {
        #expect(!CodeSignature.signedByTeam(URL(fileURLWithPath: "/bin/ls"), identifier: "com.apple.ls", teamId: CodeSignature.team))
    }

    @Test func missingHelperRefuses() throws {
        let d = try Self.temp(); defer { try? FileManager.default.removeItem(at: d) }
        let app = d.appendingPathComponent("Collie.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(!CodeSignature.appAndHelpers(d.appendingPathComponent("Collie.app"), teamId: CodeSignature.team))
    }

    @Test func garbageDmgRefused() throws {
        let d = try Self.temp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("Collie-0.2.0.dmg")
        try Data(repeating: 0x42, count: 4096).write(to: f)
        #expect(!CodeSignature.dmgNotarized(f, teamId: CodeSignature.team))
        #expect(!CodeSignature.dmgNotarized(d.appendingPathComponent("missing.dmg"), teamId: CodeSignature.team))
    }
}
