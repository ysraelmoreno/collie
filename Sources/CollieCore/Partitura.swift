import CryptoKit
import Foundation
import CollieProtocol

/// Position and size relative to the partitura's top-left corner.
public struct PartituraFrame: Codable, Sendable, Equatable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct PartituraTerminal: Codable, Sendable, Equatable {
    public var key: String
    public var preset: Preset
    public var command: String?     // custom only
    public var role: String?        // initial prompt
    public var isMaestro: Bool
    public var frame: PartituraFrame?
    public init(key: String, preset: Preset, command: String? = nil, role: String? = nil, isMaestro: Bool = false, frame: PartituraFrame? = nil) {
        self.key = key; self.preset = preset; self.command = command; self.role = role; self.isMaestro = isMaestro; self.frame = frame
    }
    // Tolerant decode: unknown fields (cwd, env, ...) are ignored by Codable; optional ones default.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key); preset = try c.decode(Preset.self, forKey: .preset)
        command = try c.decodeIfPresent(String.self, forKey: .command); role = try c.decodeIfPresent(String.self, forKey: .role)
        isMaestro = try c.decodeIfPresent(Bool.self, forKey: .isMaestro) ?? false
        frame = try c.decodeIfPresent(PartituraFrame.self, forKey: .frame)
    }
}

public struct PartituraPanel: Codable, Sendable, Equatable {
    public var key: String
    public var pluginId: String
    public var placement: PanelPlacement
    public var state: [String: JSONValue]
    public var frame: PartituraFrame?
    public init(key: String, pluginId: String, placement: PanelPlacement = .canvas, state: [String: JSONValue] = [:], frame: PartituraFrame? = nil) {
        self.key = key; self.pluginId = pluginId; self.placement = placement; self.state = state; self.frame = frame
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key); pluginId = try c.decode(String.self, forKey: .pluginId)
        placement = try c.decodeIfPresent(PanelPlacement.self, forKey: .placement) ?? .canvas
        state = try c.decodeIfPresent([String: JSONValue].self, forKey: .state) ?? [:]
        frame = try c.decodeIfPresent(PartituraFrame.self, forKey: .frame)
    }
}

public struct Partitura: Codable, Sendable, Equatable {
    public var format: Int = 1
    public var id: String
    public var name: String
    public var summary: String
    public var wantsFloor: Bool
    public var terminals: [PartituraTerminal]
    public var panels: [PartituraPanel]
    public var cords: [[String]]
    public var builtIn: Bool = false   // not serialized

    enum CodingKeys: String, CodingKey { case format, id, name, summary, wantsFloor, terminals, panels, cords }

    public init(id: String, name: String, summary: String = "", wantsFloor: Bool = false, terminals: [PartituraTerminal],
                panels: [PartituraPanel] = [], cords: [[String]] = [], builtIn: Bool = false) {
        self.id = id; self.name = name; self.summary = summary; self.wantsFloor = wantsFloor
        self.terminals = terminals; self.panels = panels; self.cords = cords; self.builtIn = builtIn
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format); id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        wantsFloor = try c.decodeIfPresent(Bool.self, forKey: .wantsFloor) ?? false
        terminals = try c.decodeIfPresent([PartituraTerminal].self, forKey: .terminals) ?? []
        panels = try c.decodeIfPresent([PartituraPanel].self, forKey: .panels) ?? []
        cords = try c.decodeIfPresent([[String]].self, forKey: .cords) ?? []
    }
}

public enum PartituraFormat {
    public static let maxBytes = 256 * 1024
    public static let maxTerminals = 20
    public static let maxPanels = 20
    /// Plug-ins allowed in a partitura and the state keys each may carry (device etc. are out).
    public static let allowedState: [String: Set<String>] = [
        "browser": ["url", "storage"], "design": ["file", "storage"],
        "memory": [], "artifacts": [], "designsystems": [], "work": [],
    ]

    private static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: "partitura: \(m)") }

    public static func decode(_ data: Data) throws(ProtocolError) -> Partitura {
        guard data.count <= maxBytes else { throw bad("arquivo grande demais (máximo \(maxBytes / 1024) KiB)") }
        let p: Partitura
        do { p = try JSONDecoder().decode(Partitura.self, from: data) }
        catch { throw bad("JSON inválido ou campos faltando") }
        try validate(p)
        return p
    }

    /// SHA-256 (hex) of the canonical encoding: what a preview showed, so the apply can refuse a changed partitura.
    public static func digest(_ p: Partitura) -> String {
        let d = (try? encode(p)) ?? Data()
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    public static func encode(_ p: Partitura) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(p)
    }

    private static func isKey(_ s: String, max: Int) -> Bool {
        (1...max).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }
    /// No control, format (bidi, zero-width) or line/paragraph separator scalars; `multiline` allows \n and \t.
    private static func clean(_ s: String, multiline: Bool = false) -> Bool {
        s.unicodeScalars.allSatisfy { u in
            if multiline, u == "\n" || u == "\t" { return true }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }
    /// A design `file`: a plain name (no path, not hidden, one line, at most 80 characters).
    public static func isPlainFileName(_ s: String) -> Bool {
        (1...80).contains(s.count) && !s.contains("/") && !s.contains("\\") && !s.hasPrefix(".") && clean(s)
    }
    /// Node sizes (canvas pt): a terminal's sets its PTY's cols/rows, so an untrusted file can't ask for a huge one.
    /// Minimums are the app's node minimums (320×200); panels may be as narrow as 200.
    public static let terminalWidth = 320.0...4000, terminalHeight = 200.0...4000, panelSize = 200.0...4000
    /// |x| and |y| at most this.
    public static let maxOffset = 100_000.0
    private static func frameOK(_ f: PartituraFrame?, terminal: Bool) -> Bool {
        guard let f else { return true }
        return [f.x, f.y].allSatisfy { $0.isFinite && abs($0) <= maxOffset }
            && (terminal ? terminalWidth : panelSize).contains(f.w) && (terminal ? terminalHeight : panelSize).contains(f.h)
    }
    private static func sizeText(terminal: Bool) -> String {
        terminal ? "posição inválida (terminal de 320×200 a 4000×4000, x e y até 100000)"
                 : "posição inválida (painel de 200×200 a 4000×4000, x e y até 100000)"
    }

    public static func validate(_ p: Partitura) throws(ProtocolError) {
        guard p.format == 1 else { throw bad("formato \(p.format) não suportado") }
        guard isKey(p.id, max: 64) else { throw bad("id inválido") }
        guard !p.name.trimmingCharacters(in: .whitespaces).isEmpty, p.name.count <= 80, clean(p.name) else { throw bad("nome inválido") }
        guard p.summary.count <= 500 else { throw bad("descrição longa demais") }
        guard clean(p.summary) else { throw bad("descrição com caracteres de controle") }
        guard p.terminals.count <= maxTerminals else { throw bad("terminais demais (máximo \(maxTerminals))") }
        guard p.panels.count <= maxPanels else { throw bad("painéis demais (máximo \(maxPanels))") }
        var keys = Set<String>()
        var terminalKeys = Set<String>()
        for t in p.terminals {
            guard isKey(t.key, max: 24) else { throw bad("chave inválida '\(t.key)'") }
            guard keys.insert(t.key).inserted else { throw bad("chave repetida '\(t.key)'") }
            terminalKeys.insert(t.key)
            if t.preset == .custom {
                guard let c = t.command, !c.isEmpty else { throw bad("'\(t.key)': o preset custom precisa de um comando") }
                guard c.count <= 1000 else { throw bad("'\(t.key)': comando longo demais") }
                guard clean(c) else { throw bad("'\(t.key)': o comando deve ter uma linha só, sem caracteres de controle") }
            } else if t.command != nil { throw bad("'\(t.key)': comando só é permitido com o preset custom") }
            if let r = t.role {
                guard r.count <= 4000 else { throw bad("'\(t.key)': papel longo demais") }
                guard clean(r, multiline: true) else { throw bad("'\(t.key)': papel com caracteres de controle") }
            }
            guard frameOK(t.frame, terminal: true) else { throw bad("'\(t.key)': \(sizeText(terminal: true))") }
        }
        guard p.terminals.filter(\.isMaestro).count <= 1 else { throw bad("no máximo um terminal Maestro") }
        var panelKeys = Set<String>()
        for a in p.panels {
            guard isKey(a.key, max: 24) else { throw bad("chave inválida '\(a.key)'") }
            guard keys.insert(a.key).inserted else { throw bad("chave repetida '\(a.key)'") }
            panelKeys.insert(a.key)
            guard let allowed = allowedState[a.pluginId] else { throw bad("plug-in '\(a.pluginId)' não é permitido") }
            for (k, v) in a.state {
                guard allowed.contains(k) else { throw bad("'\(a.key)': chave de estado '\(k)' não é permitida") }
                if k == "storage" {
                    guard case .string(let s) = v, StorageScope(rawValue: s) != nil else { throw bad("'\(a.key)': storage deve ser isolated, workspace ou global") }
                }
                if a.pluginId == "browser", k == "url" {
                    guard case .string(let s) = v, clean(s), let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                          !(u.host ?? "").isEmpty
                    else { throw bad("'\(a.key)': o endereço deve ser http ou https com um host") }
                }
                if a.pluginId == "design", k == "file" {
                    guard case .string(let s) = v, isPlainFileName(s) else { throw bad("'\(a.key)': file deve ser um nome simples") }
                }
            }
            guard frameOK(a.frame, terminal: false) else { throw bad("'\(a.key)': \(sizeText(terminal: false))") }
        }
        var seen = Set<Set<String>>()
        for c in p.cords {
            guard c.count == 2, c[0] != c[1] else { throw bad("uma corda precisa de duas chaves diferentes") }
            for k in c where !keys.contains(k) { throw bad("corda com chave desconhecida '\(k)'") }
            guard terminalKeys.contains(c[0]) || terminalKeys.contains(c[1]) else { throw bad("corda entre dois painéis") }
            guard seen.insert(Set(c)).inserted else { throw bad("corda repetida \(c[0])-\(c[1])") }
        }
    }

    /// Lowercase, accents stripped, non `[a-z0-9]` runs to `-`, trimmed, at most 24 chars.
    public static func slug(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        for u in folded.unicodeScalars {
            let ok = (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57)
            if ok { out.unicodeScalars.append(u) } else if out.last != "-" { out.append("-") }
        }
        let cut = String(out.drop { $0 == "-" }.prefix(24))
        return String(cut.reversed().drop { $0 == "-" }.reversed())
    }

    public static func memberName(apply: String, key: String) -> String {
        let s = slug(apply)
        return "\(s.isEmpty ? "partitura" : s)-\(key)"
    }
}

extension Partitura {
    private static func row(_ i: Int) -> PartituraFrame { PartituraFrame(x: Double(i) * 680, y: 0, w: 640, h: 400) }
    private static func below(_ i: Int) -> PartituraFrame { PartituraFrame(x: Double(i) * 680, y: 440, w: 640, h: 400) }

    /// Built-in partituras (original texts, pt-BR).
    public static let factory: [Partitura] = [
        Partitura(
            id: "feature-fullstack", name: "Feature fullstack",
            summary: "Maestro, backend, interface e revisor com os painéis Design e Navegador.", wantsFloor: true,
            terminals: [
                PartituraTerminal(key: "maestro", preset: .claude, role: "Você coordena esta feature. Quebre o trabalho em partes, delegue ao backend e à interface pelas cordas, peça revisão ao revisor antes de dar como pronto e mantenha `collie work` atualizado.", isMaestro: true, frame: row(0)),
                PartituraTerminal(key: "backend", preset: .claude, role: "Você implementa a parte de servidor e dados desta feature, com testes. Responda ao Maestro com o que mudou e o que falta.", frame: row(1)),
                PartituraTerminal(key: "interface", preset: .claude, role: "Você implementa a interface desta feature. Use o painel Design como referência e o Navegador para conferir o resultado. Responda ao Maestro com o que mudou.", frame: row(2)),
                PartituraTerminal(key: "revisor", preset: .claude, role: "Você revisa o que o Maestro pedir: procure bugs, casos não cobertos e testes faltando. Seja direto; não reescreva o código dos outros.", frame: row(3)),
            ],
            panels: [
                PartituraPanel(key: "design", pluginId: "design", placement: .canvas, state: ["file": .string("Feature")], frame: below(2)),
                PartituraPanel(key: "navegador", pluginId: "browser", placement: .canvas, frame: below(3)),
            ],
            cords: [["maestro", "backend"], ["maestro", "interface"], ["maestro", "revisor"], ["interface", "design"], ["interface", "navegador"]],
            builtIn: true),
        Partitura(
            id: "investigar-bug", name: "Investigar bug",
            summary: "Maestro, investigador da causa e quem escreve o teste que falha.", wantsFloor: false,
            terminals: [
                PartituraTerminal(key: "maestro", preset: .claude, role: "Você coordena a investigação de um bug. Peça ao investigador a causa com evidência e a quem testa um teste que falhe antes da correção.", isMaestro: true, frame: row(0)),
                PartituraTerminal(key: "investigador", preset: .claude, role: "Você encontra a causa raiz do bug com evidência (logs, reprodução, leitura do código). Não corrija antes de explicar a causa ao Maestro.", frame: row(1)),
                PartituraTerminal(key: "testes", preset: .claude, role: "Você escreve o teste que reproduz o bug e falha agora. Mostre a falha ao Maestro.", frame: row(2)),
            ],
            cords: [["maestro", "investigador"], ["maestro", "testes"]],
            builtIn: true),
    ]
}

extension PartituraFrame {
    /// Within what `PartituraFormat.validate` accepts (a saved canvas never fails on a node's size or place).
    public func clamped(terminal: Bool) -> PartituraFrame {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
        let m = PartituraFormat.maxOffset
        return PartituraFrame(x: c(x, -m...m), y: c(y, -m...m),
                              w: c(w, terminal ? PartituraFormat.terminalWidth : PartituraFormat.panelSize),
                              h: c(h, terminal ? PartituraFormat.terminalHeight : PartituraFormat.panelSize))
    }
}

extension Partitura {
    /// Items without a frame get 640×400 cells in a row under the framed ones (from x 0), so every created node has a place.
    public var withGridFrames: Partitura {
        var p = self
        let framed = (terminals.compactMap(\.frame) + panels.compactMap(\.frame))
        let y = framed.map { $0.y + $0.h }.max().map { $0 + 40 } ?? 0
        var i = 0
        func next() -> PartituraFrame { defer { i += 1 }; return PartituraFrame(x: Double(i) * 680, y: y, w: 640, h: 400) }
        for k in p.terminals.indices where p.terminals[k].frame == nil { p.terminals[k].frame = next() }
        for k in p.panels.indices where p.panels[k].frame == nil { p.panels[k].frame = next() }
        return p
    }
}
