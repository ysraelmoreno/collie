import Foundation
import CollieNetwork
import CollieProtocol

/// The map rules (`network.rule-*`), global to the Mac: `file` (`<root>/network/rules.json`) keeps them all; `active`
/// (`<runDir>/network/rules.json`) is what every mitmdump's addon reads: the enabled ones, in order (`MapRule.activeFile`).
/// Both are rewritten on every change, atomically (rename) and 0600. A daemon start loads them all **disabled**: a mock
/// never stays on by surprise.
actor RuleStore {
    let file: URL, active: URL
    private var rules: [MapRule]

    init(file: URL, active: URL) {
        self.file = file; self.active = active
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([MapRule].self, from: $0) } ?? []
        rules = saved.map { var r = $0; r.enabled = false; return r }
        try? Self.write(MapRule.activeFile([]), to: active)
        try? Self.write((try? JSONEncoder().encode(rules)) ?? Data("[]".utf8), to: file)
    }

    func all() -> [MapRule] { rules }

    /// Appended (last in order); a clashing id gets a new one. Returns the rule as stored.
    func add(_ r: MapRule) throws(ProtocolError) -> MapRule {
        var r = r
        while rules.contains(where: { $0.id == r.id }) { r.id = MapRule.makeID() }
        try save(rules + [r])
        return r
    }

    func remove(_ id: String) throws(ProtocolError) {
        let i = try index(id)
        var next = rules; next.remove(at: i)
        try save(next)
    }

    func setEnabled(_ id: String, _ on: Bool) throws(ProtocolError) {
        let i = try index(id)
        var next = rules; next[i].enabled = on
        try save(next)
    }

    func clear() { try? save([]) }

    func rule(_ id: String) throws(ProtocolError) -> MapRule { rules[try index(id)] }

    private func index(_ id: String) throws(ProtocolError) -> Int {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { throw ProtocolError(code: .notFound, message: "No rule '\(id)'") }
        return i
    }

    /// Validates, writes both files, then keeps `next`; a refused or failed change leaves everything as it was.
    private func save(_ next: [MapRule]) throws(ProtocolError) {
        do throws(MapRuleError) { try MapRule.validate(next) } catch { throw ProtocolError(code: .invalidArgs, message: error.message) }
        do {
            try Self.write(try JSONEncoder().encode(next), to: file)
            try Self.write(MapRule.activeFile(next), to: active)
        } catch { throw ProtocolError(code: .internal, message: "cannot save the rules: \(error.localizedDescription)") }
        rules = next
    }

    /// A 0600 temp file renamed over `url`: a reader sees the old file or the new one, never half of one.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(tmp.path, url.path) == 0 else {
            let e = errno; try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }
}
