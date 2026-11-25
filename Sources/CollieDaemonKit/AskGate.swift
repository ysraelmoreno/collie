import Foundation
import CollieProtocol

/// C1: how an `ask --check` ended.
public struct AskCheckReport: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable { case passed, failed }
    public var status: Status
    public var tries: Int
    public var tail: String
    var json: JSONValue { .object(["status": .string(status.rawValue), "tries": .number(Double(tries)), "tail": .string(tail)]) }
    /// What the ask's failure says when the tries ran out.
    var failure: String { "check failed after \(tries) \(tries == 1 ? "try" : "tries")" }
}

/// C1: what an `ask --check` carries: the judge's command (kept here, in the daemon, never in the repository), the spec's
/// path, the tries and the check's own limit.
struct AskGate: Sendable {
    var command: String
    var spec: String?
    var tries: Int
    var checkTimeout: Duration
    var dir: URL
}

typealias AskCheckRun = @Sendable (_ command: String, _ dir: URL, _ timeout: Duration) async throws(ProtocolError) -> ProcessResult

extension AskGate {
    static let correctionHead = "O check falhou. Corrija e encerre o turno. Fim da saída:"
    static func notice(_ command: String) -> String { "O Collie roda este check quando você terminar e só aceita a resposta se ele passar: \(command)" }

    /// The request, the spec's path (if any) and the fixed line about the check.
    func prompt(_ request: String) -> String { request + (spec.map { "\nSpec: \($0)" } ?? "") + "\n" + Self.notice(command) }

    /// The existing files the check's text names (a path in it, absolute or from `dir`), with what they hold now.
    // ponytail: whitespace-split words, quotes trimmed; a script the check reaches indirectly is not seen (as the loop's gate)
    func scripts() -> [String: Data] {
        var found: [String: Data] = [:]
        for w in command.split(whereSeparator: \.isWhitespace).map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }) where !w.isEmpty {
            let url = w.hasPrefix("/") ? URL(fileURLWithPath: w) : dir.appendingPathComponent(w)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue, let d = try? Data(contentsOf: url) { found[w] = d }
        }
        return found
    }
}

extension AskCoordinator {
    /// `ask --check`: the target's end of turn is judged by the check, run by `run` (the daemon's: the target's folder and
    /// sandbox, no COLLIE_ env). Red: the same target hears the output's tail and goes again, up to `gate.tries`. The
    /// result's `check` says how it ended; running out of tries is not a throw: the router turns it into the ask's failure.
    func askGated(from: UUID, to: UUID, prompt: String, raw: Bool, timeout: Duration, gate: AskGate, run: @escaping AskCheckRun,
                  detached: Bool = false, askId: String? = nil, onDelivered: (@Sendable () -> Void)? = nil) async throws(ProtocolError) -> AskResult {
        let named = gate.scripts()
        // read once, before the first turn: the agent cannot authorise itself by editing its spec
        let specText = gate.spec.flatMap { try? String(contentsOf: URL(fileURLWithPath: $0, relativeTo: gate.dir), encoding: .utf8) } ?? ""
        var next = gate.prompt(prompt), tries = 0
        while true {
            var r = try await ask(from: from, to: to, prompt: next, raw: raw, timeout: timeout, detached: detached, askId: askId,
                                  onDelivered: tries == 0 ? onDelivered : nil)
            tries += 1
            var tail: String, passed = false
            if let why = Self.tampered(named, gate: gate, spec: specText) {
                tail = why
            } else {
                do {
                    let res = try await run(gate.command, gate.dir, gate.checkTimeout)
                    tail = WorkLoop.evidenceTail(check: res.stdout + res.stderr, gate: nil, lines: WorkLoop.precheckLines, chars: WorkLoop.precheckChars)
                    passed = res.status == 0
                } catch where error.code == .timeout {
                    tail = "o check passou de \(Int(gate.checkTimeout.components.seconds)) s"
                } catch { tail = "o check não rodou: \(error.message)" }
            }
            if passed || tries >= gate.tries {
                r.check = AskCheckReport(status: passed ? .passed : .failed, tries: tries, tail: tail)
                return r
            }
            next = AskGate.correctionHead + "\n" + tail
        }
    }

    /// Why the attempt may not go to the check: a script the check names, that existed before, was changed or removed
    /// (unless the spec names it). nil: it was not.
    static func tampered(_ before: [String: Data], gate: AskGate, spec: String) -> String? {
        let now = gate.scripts()
        for (w, d) in before.sorted(by: { $0.key < $1.key }) where now[w] != d && !spec.contains(w) {
            return "a tentativa alterou «\(w)», que o check executa"
        }
        return nil
    }
}
