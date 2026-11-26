import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func call(_ d: Daemon, _ p: Paths, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "l", token: d.adminToken, command: "admin.language", args: args), timeoutSeconds: 60)
}

@Suite(.serialized) struct LanguageCommandsTests {
    @Test func setEnPersistsAndActivates() async throws {
        try await withDaemon { d, p in
            defer { L10n.set(.pt) }
            let r = try await call(d, p, ["language": .string("en")])
            #expect(r.result == .object(["language": .string("en"), "active": .string("en")]), "\(r)")
            #expect(CollieSettings.load(p.root).language == "en")
            #expect(L10n.current == .en)
        }
    }

    @Test func readOnlyReturnsCurrent() async throws {
        try await withDaemon { d, p in
            defer { L10n.set(.pt) }
            _ = try await call(d, p, ["language": .string("pt")])
            let r = try await call(d, p)
            #expect(r.result == .object(["language": .string("pt"), "active": .string("pt")]), "\(r)")
        }
    }

    @Test func invalidRejected() async throws {
        try await withDaemon { d, p in
            let r = try await call(d, p, ["language": .string("xx")])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            #expect(CollieSettings.load(p.root).language == nil)
        }
    }

    @Test func unreadableSettingsFollowSystem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json".utf8).write(to: CollieSettings.file(root))
        #expect(Lang.resolve(.parse(CollieSettings.load(root).language), preferred: ["fr"]) == .en)
    }

    @Test func launchSpecCarriesLang() async throws {
        try await withDaemon { d, p in
            defer { L10n.set(.pt) }
            let rec = TerminalRecord(id: UUID(), name: "T", preset: .shell, command: nil, cwd: "/", isShepherd: false)
            _ = try await call(d, p, ["language": .string("pt")])
            let before = try await d.router.launchSpec(rec, token: "t", user: [:])
            _ = try await call(d, p, ["language": .string("en")])
            let after = try await d.router.launchSpec(rec, token: "t", user: [:])
            #expect(before.environment["COLLIE_LANG"] == "pt")
            #expect(after.environment["COLLIE_LANG"] == "en")
        }
    }
}
