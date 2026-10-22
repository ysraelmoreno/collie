import CoreGraphics
import Foundation
import CollieCore
import CollieProtocol

/// One `partitura.list` entry.
public struct PartituraListItem: Decodable, Identifiable, Equatable, Sendable {
    public let id: String, name: String, summary: String, wantsFloor: Bool, builtIn: Bool, terminals: Int, panels: Int
}

/// Everything a partitura creates, shown before anything is applied or imported. `imported`: from a file (untrusted).
public struct PartituraPreview: Equatable, Sendable {
    public let partitura: Partitura
    public let imported: Bool
    /// New on every fetch: the sheet confirms only once this very preview has been drawn.
    public let token = UUID()
    public var id: String { partitura.id }
    /// What `partitura.apply` checks (`expect`): the daemon refuses a partitura changed since this preview.
    public var digest: String { PartituraFormat.digest(partitura) }
    /// `preset: custom` terminals' commands, verbatim, by key.
    public var commands: [(key: String, command: String)] { partitura.terminals.compactMap { t in t.command.map { (t.key, $0) } } }
    /// Initial prompts, verbatim, by key.
    public var prompts: [(key: String, role: String)] { partitura.terminals.compactMap { t in t.role.map { (t.key, $0) } } }
    public static func == (a: Self, b: Self) -> Bool { a.partitura == b.partitura && a.imported == b.imported && a.token == b.token }
}

/// List, preview, apply, save, import and export of partituras for the app (admin `call`).
@MainActor public final class PartiturasModel: ObservableObject {
    @Published public private(set) var items: [PartituraListItem] = []
    @Published public private(set) var preview: PartituraPreview?
    @Published public private(set) var error: String?
    @Published public private(set) var busy = false

    private let call: PanelHostContext.Call
    /// A node's current name (the daemon's `partitura.save` takes names).
    private let nodeName: @MainActor (UUID) -> String?
    /// The canvas point of the app's application in flight; `partitura.applied` (by the app) consumes it.
    private var anchor: CGPoint?
    /// The checked file waiting for "Importar".
    private var pendingImport: String?

    public init(call: @escaping PanelHostContext.Call, nodeName: @escaping @MainActor (UUID) -> String?) {
        self.call = call; self.nodeName = nodeName
    }

    private func send(_ command: String, _ args: [String: JSONValue] = [:]) async -> JSONValue? {
        do { return try await call(command, args) } catch { self.error = error.message; return nil }
    }

    public func refresh() async {
        guard let v = await send("partitura.list") else { return }
        do { items = try JSONDecoder().decode([PartituraListItem].self, from: JSONEncoder().encode(v)) }
        catch { self.error = "lista inválida" }
    }

    public func select(_ id: String) async {
        error = nil
        guard let v = await send("partitura.get", ["id": .string(id)]) else { preview = nil; return }
        do { preview = PartituraPreview(partitura: try JSONDecoder().decode(Partitura.self, from: JSONEncoder().encode(v)), imported: false) }
        catch { preview = nil; self.error = "partitura inválida" }
    }

    /// `partitura.apply` on `onFloor` (the floor on screen; nil: Térreo); nil on success, else the error (the sheet stays
    /// open and shows it).
    public func apply(id: String, name: String, floor: Bool?, cwd: String, onFloor: String?, at anchor: CGPoint) async -> String? {
        // always apply exactly what was previewed: without a matching preview there is nothing to `expect`
        guard let pv = preview, pv.id == id else { let m = "prévia da partitura não carregada; abra a partitura de novo"; error = m; return m }
        busy = true; error = nil
        defer { busy = false }
        self.anchor = anchor
        var args: [String: JSONValue] = ["id": .string(id), "name": .string(name), "cwd": .string(cwd), "expect": .string(pv.digest)]
        if let floor { args["floor"] = .bool(floor) }
        if let onFloor { args["onFloor"] = .string(onFloor) }
        do { _ = try await call("partitura.apply", args); return nil }
        catch { self.anchor = nil; self.error = error.message; return error.message }
    }

    /// The click point of the app's last application (once).
    public func takeAnchor() -> CGPoint? { defer { anchor = nil }; return anchor }

    /// `partitura.save` of these nodes; frames are sent relative to their top-left corner, roles without blanks.
    /// The daemon's warnings, or nil when it failed (`error`).
    public func save(name: String, summary: String = "", terminals: [UUID], panels: [UUID], frames: [UUID: CGRect],
                     roles: [UUID: String], wantsFloor: Bool) async -> [String]? {
        busy = true; error = nil
        defer { busy = false }
        let picked = terminals + panels
        let rects = picked.compactMap { frames[$0] }
        let x0 = rects.map(\.minX).min() ?? 0, y0 = rects.map(\.minY).min() ?? 0
        var f: [String: JSONValue] = [:], r: [String: JSONValue] = [:]
        for id in picked {
            guard let n = nodeName(id) else { continue }
            if let rc = frames[id] {
                f[n] = .object(["x": .number(rc.minX - x0), "y": .number(rc.minY - y0), "w": .number(rc.width), "h": .number(rc.height)])
            }
            if let role = roles[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty { r[n] = .string(role) }
        }
        var args: [String: JSONValue] = [
            "name": .string(name), "terminals": .array(terminals.compactMap { nodeName($0).map { .string($0) } }),
            "panels": .array(panels.compactMap { nodeName($0).map { .string($0) } }), "frames": .object(f), "roles": .object(r),
            "summary": .string(summary),
        ]
        if wantsFloor { args["wantsFloor"] = .bool(true) }
        do {
            let v = try await call("partitura.save", args)
            await refresh()
            guard case .object(let o) = v, case .array(let w)? = o["warnings"] else { return [] }
            return w.compactMap { if case .string(let s) = $0 { s } else { nil } }
        } catch { self.error = error.message; return nil }
    }

    /// Reads and checks a `.colliepartitura` locally (size first, nothing sent): its preview, marked imported, or nil (`error`).
    /// Nothing is saved until `confirmImport`.
    public func importFile(_ url: URL) async -> PartituraPreview? {
        error = nil; pendingImport = nil
        let read = await Task.detached { () -> Result<Data, ProtocolError> in
            func fail(_ m: String) -> Result<Data, ProtocolError> { .failure(ProtocolError(code: .invalidArgs, message: m)) }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return fail("tamanho do arquivo desconhecido") }
            guard size <= PartituraFormat.maxBytes else { return fail("arquivo grande demais (máximo 256 KiB)") }
            // at most maxBytes + 1 even if it grew since the check: decode refuses the extra byte
            guard let h = try? FileHandle(forReadingFrom: url) else { return fail("não foi possível ler o arquivo") }
            defer { try? h.close() }
            guard let d = try? h.read(upToCount: PartituraFormat.maxBytes + 1) else { return fail("não foi possível ler o arquivo") }
            return .success(d)
        }.value
        do throws(ProtocolError) {
            let data = try read.get()
            let p = try PartituraFormat.decode(data)
            pendingImport = String(decoding: data, as: UTF8.self)
            preview = PartituraPreview(partitura: p, imported: true)
            return preview
        } catch { self.error = error.message; return nil }
    }

    /// `partitura.import` of the file checked by `importFile` (`replace`: over a saved one of the same id); then it is selected.
    public func confirmImport(replace: Bool = false) async {
        guard let json = pendingImport else { return }
        busy = true; error = nil
        defer { busy = false }
        var args: [String: JSONValue] = ["json": .string(json)]
        if replace { args["replace"] = .bool(true) }
        guard case .object(let o)? = await send("partitura.import", args), case .string(let id)? = o["id"] else { return }
        pendingImport = nil
        await refresh()
        await select(id)
    }

    /// Drops the imported preview without saving.
    public func cancelImport() { pendingImport = nil; if preview?.imported == true { preview = nil } }

    /// `partitura.export` written to `url` (off main).
    public func export(id: String, to url: URL) async {
        guard case .object(let o)? = await send("partitura.export", ["id": .string(id)]), case .string(let json)? = o["json"] else { return }
        let err = await Task.detached { () -> String? in
            do { try Data(json.utf8).write(to: url, options: .atomic); return nil } catch { return "não foi possível gravar: \(error.localizedDescription)" }
        }.value
        if let err { error = err }
    }

    /// `partitura.remove`: set aside in partituras/.removed.
    public func remove(id: String) async {
        guard await send("partitura.remove", ["id": .string(id)]) != nil else { return }
        if preview?.id == id { preview = nil }
        await refresh()
    }
}
