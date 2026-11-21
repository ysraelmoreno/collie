import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func parse(_ s: String) -> Result<(config: ProjectWorkConfig, warnings: [String]), ProjectWorkConfig.ConfigError> {
    ProjectWorkConfig.parse(Data(s.utf8))
}
private func error(_ s: String) -> ProjectWorkConfig.ConfigError? {
    if case .failure(let e) = parse(s) { e } else { nil }
}
private func config(_ s: String) throws -> ProjectWorkConfig {
    switch parse(s) {
    case .success(let ok): return ok.config
    case .failure(let e): Issue.record("\(e.message)"); throw e
    }
}

private let full = """
{ "version": 1,
  "gate": "scripts/ci/lint.sh && scripts/ci/check-architecture.sh",
  "precheck": "swift build --build-tests",
  "smoke": "scripts/laco-check.sh --smoke",
  "areas": { "ask": "swift test --filter AskTests", "quadro": "scripts/check-onda12.sh q12-1" },
  "full": "scripts/laco-check.sh --full" }
"""

/// A project folder (with `.git`, so it is its own root) the test removes at the end.
private func project(_ body: (URL) async throws -> Void) async throws {
    let dir = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory))
        .appendingPathComponent("pwc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
private func output(_ r: Response) -> String {
    if case .object(let o)? = r.result, case .string(let s)? = o["output"] { s } else { "<\(r)>" }
}
private func workConfig(_ d: Daemon, _ p: Paths, cwd: URL) async throws -> Response {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                      args: ["name": .string("T"), "preset": .string("shell"), "cwd": .string(cwd.path)]))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    let token = try await tokenOf(d, id)
    return try await send(p, Request(id: "c", terminalId: id, token: token, command: "work.config"))
}

@Suite struct ProjectWorkConfigTests {
    // MARK: parse

    @Test func fullFileDecodes() throws {
        let c = try config(full)
        #expect(c.gate == "scripts/ci/lint.sh && scripts/ci/check-architecture.sh")
        #expect(c.precheck == "swift build --build-tests")
        #expect(c.smoke == "scripts/laco-check.sh --smoke")
        #expect(c.full == "scripts/laco-check.sh --full")
        #expect(c.areas == ["ask": "swift test --filter AskTests", "quadro": "scripts/check-onda12.sh q12-1"])
        if case .success(let ok) = parse(full) { #expect(ok.warnings.isEmpty) }
    }

    @Test func emptyAndVersionOnlyAreValid() throws {
        #expect(try config("{}") == ProjectWorkConfig())
        #expect(try config(#"{"version":1}"#) == ProjectWorkConfig())
        #expect(try config(#"{"version":1.0}"#) == ProjectWorkConfig())
    }

    @Test func errorsAreDistinctAndClear() {
        #expect(error(#"{"gate": 3}"#) == .wrongType(key: "gate", expected: "texto"))
        #expect(error(#"{"areas": ["a"]}"#) == .wrongType(key: "areas", expected: "objeto"))
        #expect(error(#"{"areas": {"ask": 1}}"#) == .wrongType(key: "areas.ask", expected: "texto"))
        #expect(error(#"{"version": "1"}"#) == .wrongType(key: "version", expected: "número"))
        #expect(error(#"{"version": true}"#) == .wrongType(key: "version", expected: "número"))
        #expect(error(#"{"version": 2}"#) == .unsupportedVersion("2"))
        #expect(error(#"{"version": 1.5}"#) == .unsupportedVersion("1.5"))
        #expect(error(#"{"gate": "x""#) == .notJSON)
        #expect(error("[1]") == .notObject)
        #expect(error("") == .notJSON)
        let big = "{\"gate\": \"" + String(repeating: "a", count: 17 * 1024) + "\"}"
        #expect(error(big) == .tooLarge(big.utf8.count))
        #expect(error("{\"gate\": \"" + String(repeating: "a", count: 1001) + "\"}") == .commandTooLong(key: "gate", length: 1001))
        #expect(error("{\"gate\": \"" + String(repeating: "a", count: 1000) + "\"}") == nil)
        #expect(error(#"{"smoke": "a\nb"}"#) == .controlCharacter(key: "smoke"))
        #expect(error(#"{"smoke": "a\u0000b"}"#) == .controlCharacter(key: "smoke"))
        #expect(error(#"{"areas": {"ask": "a\tb"}}"#) == .controlCharacter(key: "areas.ask"))
        #expect(error(#"{"full": "  "}"#) == .emptyCommand(key: "full"))
        #expect(error(#"{"areas": {"Ask": "x"}}"#) == .badAreaName("Ask"))
        #expect(error(#"{"areas": {"a/b": "x"}}"#) == .badAreaName("a/b"))
        #expect(error(#"{"areas": {"": "x"}}"#) == .badAreaName(""))
        let long = String(repeating: "a", count: 41)
        #expect(error("{\"areas\": {\"\(long)\": \"x\"}}") == .badAreaName(long))
        #expect(error("{\"areas\": {\"\(String(long.dropLast()))\": \"x\"}}") == nil)
        let many = (1...51).map { "\"a\($0)\": \"x\"" }.joined(separator: ",")
        #expect(error("{\"areas\": {\(many)}}") == .tooManyAreas(51))
        #expect(error("{\"areas\": {\((1...50).map { "\"a\($0)\": \"x\"" }.joined(separator: ","))}}") == nil)
        // every message says what is wrong, in words, and no two errors read the same
        let all: [ProjectWorkConfig.ConfigError] = [.notJSON, .notObject, .tooLarge(17000), .wrongType(key: "gate", expected: "texto"),
                                                    .unsupportedVersion("2"), .commandTooLong(key: "gate", length: 1001),
                                                    .controlCharacter(key: "gate"), .emptyCommand(key: "gate"), .badAreaName("A"),
                                                    .tooManyAreas(51), .unknownArea("x", available: ["ask"]), .noAreas]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(all.allSatisfy { !$0.message.isEmpty })
    }

    @Test func unknownKeyIsAWarning() throws {
        guard case .success(let ok) = parse(#"{"version":1, "gate":"g", "futuro": {"x":1}, "outro": 2}"#) else { Issue.record("not ok"); return }
        #expect(ok.config.gate == "g")
        #expect(ok.warnings == ["chave desconhecida ignorada: futuro", "chave desconhecida ignorada: outro"])
    }

    // MARK: composeCheck

    @Test func composeCheck() throws {
        let c = try config(full)
        #expect(c.composeCheck(areas: ["ask"]) == .success("swift test --filter AskTests && scripts/laco-check.sh --smoke"))
        #expect(c.composeCheck(areas: ["ask", "quadro"])
                == .success("swift test --filter AskTests && scripts/check-onda12.sh q12-1 && scripts/laco-check.sh --smoke"))
        #expect(c.composeCheck(areas: ["ask", "ask"]) == .success("swift test --filter AskTests && scripts/laco-check.sh --smoke"))
        var noSmoke = c; noSmoke.smoke = nil
        #expect(noSmoke.composeCheck(areas: ["ask"]) == .success("swift test --filter AskTests"))
        #expect(noSmoke.composeCheck(areas: ["quadro", "ask"]) == .success("scripts/check-onda12.sh q12-1 && swift test --filter AskTests"))
        #expect(c.composeCheck(areas: ["nope"]) == .failure(.unknownArea("nope", available: ["ask", "quadro"])))
        if case .failure(let e) = c.composeCheck(areas: ["nope"]) { #expect(e.message.contains("ask, quadro")) }
        #expect(ProjectWorkConfig().composeCheck(areas: ["ask"]) == .failure(.unknownArea("ask", available: [])))
        #expect(c.composeCheck(areas: []) == .failure(.noAreas))
    }

    // MARK: work.config

    @Test func workConfigWithoutFile() async throws {
        try await project { dir in
            try await withDaemon { d, p in
                let r = try await workConfig(d, p, cwd: dir)
                #expect(r.ok, "\(r)")
                #expect(output(r) == "nenhum collie-work.json neste projeto")
            }
        }
    }

    @Test func workConfigWithFile() async throws {
        try await project { dir in
            let marker = dir.appendingPathComponent("ran-\(UUID().uuidString.prefix(6))")
            let body = """
            { "version": 1, "gate": "touch \(marker.path)-gate", "precheck": "touch \(marker.path)-pre",
              "smoke": "touch \(marker.path)-smoke", "full": "touch \(marker.path)-full",
              "areas": { "ask": "touch \(marker.path)", "b\\u202Eidi": "x" }, "novo\\u0007": 1 }
            """
            // the area name with a bidi override is refused; one without, and an unknown key with a control character, below
            #expect(error(body) == .badAreaName("b\u{202E}idi"))
            let ok = body.replacingOccurrences(of: "\"b\\u202Eidi\": \"x\"", with: "\"quadro\": \"echo q\"")
            try Data(ok.utf8).write(to: dir.appendingPathComponent("collie-work.json"))
            try await withDaemon { d, p in
                let r = try await workConfig(d, p, cwd: dir)
                #expect(r.ok, "\(r)")
                let out = output(r)
                #expect(out.contains(dir.appendingPathComponent("collie-work.json").path))
                #expect(out.contains("árvore de trabalho"))
                #expect(out.contains("gate: touch \(marker.path)-gate"))
                #expect(out.contains("precheck: touch \(marker.path)-pre"))
                #expect(out.contains("smoke: touch \(marker.path)-smoke"))
                #expect(out.contains("full: touch \(marker.path)-full"))
                #expect(out.contains("ask: touch \(marker.path) && touch \(marker.path)-smoke"))
                #expect(out.contains("quadro: echo q && touch \(marker.path)-smoke"))
                #expect(out.contains("chave desconhecida ignorada: novo"))
                // the text leaks no control character (the unknown key had a BEL), only its newlines between lines
                #expect(!out.unicodeScalars.contains { $0 != "\n" && CharacterSet.controlCharacters.contains($0) })
                // nothing from the file ran
                for suffix in ["", "-gate", "-pre", "-smoke", "-full"] {
                    #expect(!FileManager.default.fileExists(atPath: marker.path + suffix), "ran \(suffix)")
                }
            }
        }
    }

    @Test func workConfigRefusesSymlinkAndLargeFile() async throws {
        try await project { dir in
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("pwc-out-\(UUID().uuidString.prefix(8)).json")
            try Data(#"{"gate":"g"}"#.utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let file = dir.appendingPathComponent("collie-work.json")
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            try await withDaemon { d, p in
                let r = try await workConfig(d, p, cwd: dir)
                #expect(!r.ok && r.error?.message.contains("link simbólico") == true, "\(r)")
                try FileManager.default.removeItem(at: file)
                try Data(("{\"gate\": \"" + String(repeating: "a", count: 17 * 1024) + "\"}").utf8).write(to: file)
                let big = try await workConfig(d, p, cwd: dir)
                #expect(!big.ok && big.error?.message.contains("16 KB") == true, "\(big)")
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                let notFile = try await workConfig(d, p, cwd: dir)
                #expect(!notFile.ok && notFile.error?.message.contains("arquivo regular") == true, "\(notFile)")
            }
        }
    }

    @Test func readerAppliesTheRealRules() throws {
        // the file reader alone, against the same folder rules: absent, refused, loaded
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pwc-r-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WorkConfigFile.read(root: dir) == .absent)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("collie-work.json"))
        #expect(WorkConfigFile.read(root: dir) == .loaded(Data("{}".utf8)))
        #expect(WorkConfigFile.read(root: dir.appendingPathComponent("..").appendingPathComponent(dir.lastPathComponent))
                == .refused("o caminho do projeto contém '..'"))
    }
}
