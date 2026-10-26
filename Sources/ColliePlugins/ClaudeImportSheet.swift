import AppKit
import Foundation
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI

/// The "Importar do Claude…" sheet's state (pure: tested without the daemon). Each link sent: a row, pending until the
/// daemon's `artifact.added` with that `url` (importado) or `artifact.import.failed` (falhou, with the reason).
/// "Importar meus artifacts": the terminal's list (`artifact.import.list`), ticked by the user, imported 50 at a time.
public struct ClaudeImportProgress: Equatable {
    public enum State: Equatable { case pending, imported, failed(String) }
    public struct Item: Equatable, Identifiable {
        public let url: String
        public var title: String?
        public var state: State
        public var id: String { url }
    }
    public private(set) var items: [Item] = []
    public private(set) var listed: [Item] = []
    public var ticked: Set<String> = []
    /// Waiting for the terminal's list (asked with `listNonce`); why it failed.
    public private(set) var listing = false
    public private(set) var listError: String?
    /// The nonces of the imports this sheet sent (`artifact.import-claude`): reports with another are not ours.
    private var nonces: Set<String> = []
    private var listNonce: String?
    public init() {}

    public var pendingCount: Int { items.filter { $0.state == .pending }.count }
    /// The ticked links, in list order, at most 50.
    public var batch: [String] { Array(listed.map(\.url).filter(ticked.contains).prefix(ClaudeLinks.maxPerImport)) }

    /// The terminal was asked for the user's list, with `nonce`.
    public mutating func listingStarted(nonce: String) { listing = true; listNonce = nonce; listError = nil }

    /// Links just sent with `nonce`: pending (again), each once.
    public mutating func started(_ links: [String], nonce: String) {
        nonces.insert(nonce)
        for l in links {
            let title = listed.first { $0.url == l }?.title
            if let i = items.firstIndex(where: { $0.url == l }) { items[i].state = .pending } else { items.append(Item(url: l, title: title, state: .pending)) }
        }
        ticked.subtract(links)
    }

    /// An `artifact.*` event; true when it changed the sheet.
    @discardableResult public mutating func apply(_ event: String, _ payload: JSONValue) -> Bool {
        guard case .object(let o) = payload else { return false }
        func s(_ k: String) -> String? { if case .string(let v)? = o[k] { v } else { nil } }
        // only the asked terminal's reports carry the nonce the daemon handed this sheet
        guard let nonce = s("nonce") else { return false }
        switch event {
        case "artifact.added":
            guard nonces.contains(nonce), let u = s("url"), let i = items.firstIndex(where: { $0.url == u }) else { return false }
            items[i].state = .imported
        case "artifact.import.failed":
            let why = s("reason") ?? "falhou"
            if s("url") == "" { guard listing, nonce == listNonce else { return false }; listing = false; listError = why; return true }
            guard nonces.contains(nonce), let u = s("url"), let i = items.firstIndex(where: { $0.url == u }) else { return false }
            items[i].state = .failed(why)
        case "artifact.import.list":
            guard listing, nonce == listNonce, case .array(let a)? = o["items"] else { return false }
            listed = a.compactMap { v in
                guard case .object(let e) = v, case .string(let u)? = e["url"], ClaudeLinks.isLink(u) else { return nil }
                if case .string(let t)? = e["title"] { return Item(url: u, title: t, state: .pending) }
                return Item(url: u, title: nil, state: .pending)
            }
            listing = false; listError = nil
        default: return false
        }
        return true
    }
}

/// What a drop onto the Artifacts panel adds: .html/.htm files, folders (not links) and .zip files, local only.
public enum ArtifactDrop {
    public static func check(_ urls: [URL]) -> (accepted: [URL], refused: [String]) {
        var ok: [URL] = [], refused: [String] = []
        for u in urls {
            let v = u.isFileURL ? try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) : nil
            let ext = u.pathExtension.lowercased()
            if let v, v.isSymbolicLink != true, v.isDirectory == true || (v.isRegularFile == true && ["html", "htm", "zip"].contains(ext)) {
                ok.append(u)
            } else {
                refused.append("\(u.lastPathComponent): só páginas .html, pastas ou .zip")
            }
        }
        return (ok, refused)
    }
}

/// One Claude terminal an import can go to (`artifact.import-terminals`).
public struct ClaudeTerminalRow: Decodable, Equatable, Identifiable, Sendable {
    public let id: String, name: String, running: Bool
    public let `default`: Bool
}

/// The sheet: links pasted (or the user's list), a folder, a Claude terminal; then one row per link.
struct ClaudeImportSheet: View {
    @ObservedObject var model: ArtifactsModel
    @Binding var shown: Bool
    @State private var text = ""
    @State private var folder = ""
    @State private var terminal = ""

    private var parsed: (links: [String], bad: [String]) { ClaudeLinks.split(text) }

    var body: some View {
        let p = model.claude
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar do Claude").font(.collieUI(17, .semibold)).foregroundStyle(Color.collieText)
            Text("Um terminal Claude já logado lê os artifacts com a ferramenta dele; o Collie guarda as páginas sem precisar de rede.")
                .font(.collieUI(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            if let e = model.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger) }
            Text("Links (um por linha, até \(ClaudeLinks.maxPerImport))").font(.collieUI(12, .medium))
            TextEditor(text: $text).font(.collieMono(12)).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.collieMuted.opacity(0.4)))
                .accessibilityLabel("Links dos artifacts do claude.ai")
            if !parsed.bad.isEmpty {
                Text("Não são links de artifact do claude.ai: " + parsed.bad.prefix(3).joined(separator: ", "))
                    .font(.collieUI(12)).foregroundStyle(Color.collieAttention)
            }
            HStack {
                Picker("Pasta", selection: $folder) {
                    Text("Sem pasta").tag("")
                    ForEach(model.folders.map(\.path), id: \.self) { Text($0).tag($0) }
                }
                Picker("Terminal", selection: $terminal) {
                    if model.terminals.isEmpty { Text("Nenhum terminal Claude aberto").tag("") }
                    ForEach(model.terminals) { t in Text(t.name + (t.running ? "" : " (parado)")).tag(t.id) }
                }
            }
            HStack {
                Button("Importar \(parsed.links.count == 1 ? "1 link" : "\(parsed.links.count) links")") {
                    let links = parsed.links
                    Task { if await model.importClaude(links, folder: folder, terminal: terminal) { text = "" } }
                }
                .disabled(parsed.links.isEmpty || parsed.links.count > ClaudeLinks.maxPerImport || terminal.isEmpty || model.busy)
                .buttonStyle(CollieButtonStyle(.primary))
                Button(p.listing ? "Listando…" : "Importar meus artifacts…") { Task { await model.listClaude(terminal: terminal) } }
                    .disabled(terminal.isEmpty || p.listing || model.busy).buttonStyle(CollieButtonStyle(.secondary))
                Spacer()
                Button("Fechar") { shown = false }.buttonStyle(CollieButtonStyle(.quiet)).keyboardShortcut(.cancelAction)
            }
            if let e = p.listError { Text("Lista: \(e)").font(.collieUI(12)).foregroundStyle(Color.collieDanger) }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !p.listed.isEmpty {
                        HStack {
                            Text("Seus artifacts (\(p.listed.count))").font(.collieUI(12, .semibold))
                            Spacer()
                            Button("Importar selecionados (\(p.batch.count))") {
                                let links = p.batch
                                Task { _ = await model.importClaude(links, folder: folder, terminal: terminal) }
                            }.disabled(p.batch.isEmpty || terminal.isEmpty || model.busy).buttonStyle(CollieButtonStyle(.secondary))
                        }
                        ForEach(p.listed) { i in
                            Toggle(isOn: Binding(get: { model.claude.ticked.contains(i.url) },
                                                 set: { on in if on { model.claude.ticked.insert(i.url) } else { model.claude.ticked.remove(i.url) } })) {
                                Text(i.title ?? i.url).font(.collieUI(12)).lineLimit(1)
                            }.toggleStyle(.checkbox)
                        }
                        Divider()
                    }
                    ForEach(p.items) { i in
                        HStack(spacing: 8) {
                            Text(i.title ?? i.url).font(.collieMono(11)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            switch i.state {
                            case .pending: ProgressView().controlSize(.small); Text("aguardando").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                            case .imported: Text("importado").font(.collieMono(11, .semibold)).foregroundStyle(Color.collieAccent)
                            case .failed(let why): Text("falhou").font(.collieMono(11, .semibold)).foregroundStyle(Color.collieDanger).help(why)
                                .accessibilityLabel("falhou: \(why)")
                            }
                        }
                    }
                }
            }.frame(minHeight: 60, maxHeight: 240)
        }
        .padding(20).frame(width: 520)
        .background(Color.collieSidebar)
        .task {
            await model.loadTerminals()
            if terminal.isEmpty { terminal = model.terminals.first(where: \.default)?.id ?? model.terminals.first(where: \.running)?.id ?? "" }
        }
    }
}
