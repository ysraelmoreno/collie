import CryptoKit
import Foundation
import CollieProtocol

/// Position and size relative to the herd's top-left corner.
public struct HerdFrame: Codable, Sendable, Equatable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct HerdTerminal: Codable, Sendable, Equatable {
    public var key: String
    public var preset: Preset
    public var command: String?     // custom only
    public var role: String?        // initial prompt
    public var isShepherd: Bool
    public var frame: HerdFrame?
    public init(key: String, preset: Preset, command: String? = nil, role: String? = nil, isShepherd: Bool = false, frame: HerdFrame? = nil) {
        self.key = key; self.preset = preset; self.command = command; self.role = role; self.isShepherd = isShepherd; self.frame = frame
    }
    // Tolerant decode: unknown fields (cwd, env, ...) are ignored by Codable; optional ones default.
    private enum Legacy: String, CodingKey { case isMaestro }   // an .orqpartitura/.colliepartitura
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key); preset = try c.decode(Preset.self, forKey: .preset)
        command = try c.decodeIfPresent(String.self, forKey: .command); role = try c.decodeIfPresent(String.self, forKey: .role)
        isShepherd = try c.decodeIfPresent(Bool.self, forKey: .isShepherd)
            ?? d.container(keyedBy: Legacy.self).decodeIfPresent(Bool.self, forKey: .isMaestro) ?? false
        frame = try c.decodeIfPresent(HerdFrame.self, forKey: .frame)
    }
}

public struct HerdPanel: Codable, Sendable, Equatable {
    public var key: String
    public var pluginId: String
    public var placement: PanelPlacement
    public var state: [String: JSONValue]
    public var frame: HerdFrame?
    public init(key: String, pluginId: String, placement: PanelPlacement = .canvas, state: [String: JSONValue] = [:], frame: HerdFrame? = nil) {
        self.key = key; self.pluginId = pluginId; self.placement = placement; self.state = state; self.frame = frame
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key); pluginId = try c.decode(String.self, forKey: .pluginId)
        placement = try c.decodeIfPresent(PanelPlacement.self, forKey: .placement) ?? .canvas
        state = try c.decodeIfPresent([String: JSONValue].self, forKey: .state) ?? [:]
        frame = try c.decodeIfPresent(HerdFrame.self, forKey: .frame)
    }
}

public struct Herd: Codable, Sendable, Equatable {
    public var format: Int = 1
    public var id: String
    public var name: String
    public var summary: String
    public var wantsPaddock: Bool
    public var terminals: [HerdTerminal]
    public var panels: [HerdPanel]
    public var leashes: [[String]]
    public var builtIn: Bool = false   // not serialized

    enum CodingKeys: String, CodingKey { case format, id, name, summary, wantsPaddock, terminals, panels, leashes }
    private enum Legacy: String, CodingKey { case wantsFloor, cords }   // an .orqpartitura/.colliepartitura

    public init(id: String, name: String, summary: String = "", wantsPaddock: Bool = false, terminals: [HerdTerminal],
                panels: [HerdPanel] = [], leashes: [[String]] = [], builtIn: Bool = false) {
        self.id = id; self.name = name; self.summary = summary; self.wantsPaddock = wantsPaddock
        self.terminals = terminals; self.panels = panels; self.leashes = leashes; self.builtIn = builtIn
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format); id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        let l = try d.container(keyedBy: Legacy.self)
        wantsPaddock = try c.decodeIfPresent(Bool.self, forKey: .wantsPaddock) ?? l.decodeIfPresent(Bool.self, forKey: .wantsFloor) ?? false
        terminals = try c.decodeIfPresent([HerdTerminal].self, forKey: .terminals) ?? []
        panels = try c.decodeIfPresent([HerdPanel].self, forKey: .panels) ?? []
        leashes = try c.decodeIfPresent([[String]].self, forKey: .leashes) ?? l.decodeIfPresent([[String]].self, forKey: .cords) ?? []
    }
}

public enum HerdFormat {
    public static let maxBytes = 256 * 1024
    public static let maxTerminals = 20
    public static let maxPanels = 20
    /// Plug-ins allowed in a herd and the state keys each may carry (device etc. are out).
    public static let allowedState: [String: Set<String>] = [
        "browser": ["url", "storage"], "design": ["file", "storage"],
        "memory": [], "artifacts": [], "designsystems": [], "work": [],
    ]

    private static func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: "rebanho: \(m)") }

    public static func decode(_ data: Data) throws(ProtocolError) -> Herd {
        guard data.count <= maxBytes else { throw bad("arquivo grande demais (máximo \(maxBytes / 1024) KiB)") }
        let p: Herd
        do { p = try JSONDecoder().decode(Herd.self, from: data) }
        catch { throw bad("JSON inválido ou campos faltando") }
        try validate(p)
        return p
    }

    /// SHA-256 (hex) of the canonical encoding: what a preview showed, so the apply can refuse a changed herd.
    public static func digest(_ p: Herd) -> String {
        let d = (try? encode(p)) ?? Data()
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    public static func encode(_ p: Herd) throws -> Data {
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
    private static func frameOK(_ f: HerdFrame?, terminal: Bool) -> Bool {
        guard let f else { return true }
        return [f.x, f.y].allSatisfy { $0.isFinite && abs($0) <= maxOffset }
            && (terminal ? terminalWidth : panelSize).contains(f.w) && (terminal ? terminalHeight : panelSize).contains(f.h)
    }
    private static func sizeText(terminal: Bool) -> String {
        terminal ? "posição inválida (terminal de 320×200 a 4000×4000, x e y até 100000)"
                 : "posição inválida (painel de 200×200 a 4000×4000, x e y até 100000)"
    }

    public static func validate(_ p: Herd) throws(ProtocolError) {
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
        guard p.terminals.filter(\.isShepherd).count <= 1 else { throw bad("no máximo um terminal Pastor") }
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
        for c in p.leashes {
            guard c.count == 2, c[0] != c[1] else { throw bad("uma guia precisa de duas chaves diferentes") }
            for k in c where !keys.contains(k) { throw bad("guia com chave desconhecida '\(k)'") }
            guard terminalKeys.contains(c[0]) || terminalKeys.contains(c[1]) else { throw bad("guia entre dois painéis") }
            guard seen.insert(Set(c)).inserted else { throw bad("guia repetida \(c[0])-\(c[1])") }
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
        return "\(s.isEmpty ? "rebanho" : s)-\(key)"
    }
}

extension Herd {
    private static func row(_ i: Int) -> HerdFrame { HerdFrame(x: Double(i) * 680, y: 0, w: 640, h: 400) }
    private static func below(_ i: Int) -> HerdFrame { HerdFrame(x: Double(i) * 680, y: 440, w: 640, h: 400) }

    /// Built-in herds (original texts, pt-BR).
    public static let factory: [Herd] = [
        Herd(
            id: "feature-fullstack", name: "Feature fullstack",
            summary: "Pastor, backend, interface e revisor com os painéis Design e Navegador.", wantsPaddock: true,
            terminals: [
                HerdTerminal(key: "pastor", preset: .claude, role: "Você coordena esta feature. Quebre o trabalho em partes, delegue ao backend e à interface pelas guias, peça revisão ao revisor antes de dar como pronto e mantenha `collie work` atualizado.", isShepherd: true, frame: row(0)),
                HerdTerminal(key: "backend", preset: .claude, role: "Você implementa a parte de servidor e dados desta feature, com testes. Responda ao Pastor com o que mudou e o que falta.", frame: row(1)),
                HerdTerminal(key: "interface", preset: .claude, role: "Você implementa a interface desta feature. Use o painel Design como referência e o Navegador para conferir o resultado. Responda ao Pastor com o que mudou.", frame: row(2)),
                HerdTerminal(key: "revisor", preset: .claude, role: "Você revisa o que o Pastor pedir: procure bugs, casos não cobertos e testes faltando. Seja direto; não reescreva o código dos outros.", frame: row(3)),
            ],
            panels: [
                HerdPanel(key: "design", pluginId: "design", placement: .canvas, state: ["file": .string("Feature")], frame: below(2)),
                HerdPanel(key: "navegador", pluginId: "browser", placement: .canvas, frame: below(3)),
            ],
            leashes: [["pastor", "backend"], ["pastor", "interface"], ["pastor", "revisor"], ["interface", "design"], ["interface", "navegador"]],
            builtIn: true),
        Herd(
            id: "feature-com-design", name: "Feature com design",
            summary: "Pastor, designer, interface e tester: desenha no FigCraft, implementa e confere contra o design.", wantsPaddock: true,
            terminals: [
                HerdTerminal(key: "pastor", preset: .claude, role: "Você conduz esta feature do desenho à entrega. Peça primeiro as telas ao designer; quando ele disser quais estão prontas, passe-as à interface. Antes de dar como pronto, peça ao tester a comparação com o design e só encerre quando as diferenças estiverem resolvidas. O painel Design do rebanho já está aberto: use-o, não abra outro nem pergunte se deve desenhar antes.", isShepherd: true, frame: row(0)),
                HerdTerminal(key: "designer", preset: .claude, role: "Você desenha as telas no painel Design com `collie design …`, seguindo o design system ativo. Avise o Pastor, pela guia, quais telas estão prontas.", frame: row(1)),
                HerdTerminal(key: "interface", preset: .claude, role: "Você implementa a interface a partir do desenho: leia-o com `collie design inspect` e `collie design export`. Confira o resultado no Navegador e responda ao Pastor com o que mudou.", frame: row(2)),
                HerdTerminal(key: "tester", preset: .claude, role: "Você compara `collie design screenshot` com `collie browser screenshot` (e com os dispositivos, se houver) nas larguras que o Pastor indicar. Relate cada diferença ao Pastor, com as duas imagens.", frame: row(3)),
            ],
            panels: [
                HerdPanel(key: "design", pluginId: "design", placement: .canvas, state: ["file": .string("Feature")], frame: below(1)),
                HerdPanel(key: "navegador", pluginId: "browser", placement: .canvas, frame: below(2)),
            ],
            leashes: [["pastor", "designer"], ["pastor", "interface"], ["pastor", "tester"], ["designer", "design"], ["interface", "design"], ["interface", "navegador"], ["tester", "design"], ["tester", "navegador"]],
            builtIn: true),
        Herd(
            id: "investigar-bug", name: "Investigar bug",
            summary: "Pastor, investigador da causa e quem escreve o teste que falha.", wantsPaddock: false,
            terminals: [
                HerdTerminal(key: "pastor", preset: .claude, role: "Você coordena a investigação de um bug. Peça ao investigador a causa com evidência e a quem testa um teste que falhe antes da correção.", isShepherd: true, frame: row(0)),
                HerdTerminal(key: "investigador", preset: .claude, role: "Você encontra a causa raiz do bug com evidência (logs, reprodução, leitura do código). Não corrija antes de explicar a causa ao Pastor.", frame: row(1)),
                HerdTerminal(key: "testes", preset: .claude, role: "Você escreve o teste que reproduz o bug e falha agora. Mostre a falha ao Pastor.", frame: row(2)),
            ],
            leashes: [["pastor", "investigador"], ["pastor", "testes"]],
            builtIn: true),
    ]
}

extension HerdFrame {
    /// Within what `HerdFormat.validate` accepts (a saved canvas never fails on a node's size or place).
    public func clamped(terminal: Bool) -> HerdFrame {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound }
        let m = HerdFormat.maxOffset
        return HerdFrame(x: c(x, -m...m), y: c(y, -m...m),
                              w: c(w, terminal ? HerdFormat.terminalWidth : HerdFormat.panelSize),
                              h: c(h, terminal ? HerdFormat.terminalHeight : HerdFormat.panelSize))
    }
}

extension Herd {
    /// Items without a frame get 640×400 cells in a row under the framed ones (from x 0), so every created node has a place.
    public var withGridFrames: Herd {
        var p = self
        let framed = (terminals.compactMap(\.frame) + panels.compactMap(\.frame))
        let y = framed.map { $0.y + $0.h }.max().map { $0 + 40 } ?? 0
        var i = 0
        func next() -> HerdFrame { defer { i += 1 }; return HerdFrame(x: Double(i) * 680, y: y, w: 640, h: 400) }
        for k in p.terminals.indices where p.terminals[k].frame == nil { p.terminals[k].frame = next() }
        for k in p.panels.indices where p.panels[k].frame == nil { p.panels[k].frame = next() }
        return p
    }
}
