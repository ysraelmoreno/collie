import AppKit
import Foundation
import CollieNetwork
import CollieTheme
import SwiftUI

/// Bar (emulator, Interceptar/Parar, status, Limpar, filter), notices, then the live list beside the selected flow.
struct NetworkView: View {
    @ObservedObject var model: NetworkPanelModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            if let e = model.error ?? model.pollError { notice(e, tone: .collieDanger, icon: "exclamationmark.triangle") }
            if !model.restartSuggested.isEmpty {
                notice("Reinicie \(model.restartSuggested.joined(separator: ", ")) no emulador para que leia a CA do Collie.",
                       tone: .collieAttention, icon: "arrow.clockwise")
            }
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            HSplitView {
                FlowList(model: model).frame(minWidth: 320)
                FlowDetailView(model: model).frame(minWidth: 300)
            }
        }
        .background(Color.collieSurface)
        .task { await model.pollLoop() }   // on screen only: cancelled when the view leaves its window
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Picker("Emulador", selection: Binding(get: { model.serial ?? "" }, set: { s in Task { await model.select(serial: s) } })) {
                if model.emulators.isEmpty { Text("Nenhum emulador").tag("") }
                ForEach(model.emulators, id: \.self) { Text($0).tag($0) }
                if let s = model.serial, !model.emulators.contains(s) { Text(s).tag(s) }
            }
            .labelsHidden().frame(width: 160).disabled(model.busy || model.attached)
            .accessibilityLabel("Emulador")
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(CollieButtonStyle(.quiet)).disabled(model.busy)
                .accessibilityLabel("Recarregar emuladores")
            Button(model.attached ? "Parar" : "Interceptar") { Task { await model.toggle() } }
                .buttonStyle(CollieButtonStyle(model.attached ? .secondary : .primary))
                .disabled(model.serial == nil || model.busy)
                .accessibilityLabel(model.attached ? "Parar a interceptação" : "Interceptar o tráfego do emulador")
            status
            if model.pendingDetach { CollieTag("restaurando emulador", tone: .attention) }
            if model.dropped > 0 { CollieTag("\(model.dropped) perdidas", tone: .attention) }
            Spacer(minLength: 8)
            TextField("Filtrar host, caminho, método, status", text: $model.filter)
                .collieField().frame(maxWidth: 280).accessibilityLabel("Filtrar requisições")
            Button("Limpar") { Task { await model.clear() } }
                .buttonStyle(CollieButtonStyle(.quiet)).disabled(!model.attached)
                .accessibilityLabel("Limpar requisições capturadas")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var status: some View {
        Group {
            if model.busy { ProgressView().controlSize(.small) }
            else if model.attached { CollieTag(model.port.map { "proxy :\($0)" } ?? "interceptando", tone: .accent) }
            else { CollieTag("parado", tone: .neutral) }
        }
        .accessibilityLabel(model.attached ? "Interceptando\(model.port.map { ", porta \($0)" } ?? "")" : "Parado")
    }

    private func notice(_ text: String, tone: Color, icon: String) -> some View {
        Label(text, systemImage: icon).font(.collieUI(12)).foregroundStyle(tone).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
            .background(tone.opacity(0.08))
    }
}

extension FlowTone {
    var color: Color {
        switch self {
        case .success: .collieAccent
        case .redirect: .collieSecondary
        case .clientError: .collieAttention
        case .serverError, .failed: .collieDanger
        case .pending, .tunneled: .collieMuted
        }
    }
}

/// The live list: method, status, host, path, size, duration.
private struct FlowList: View {
    @ObservedObject var model: NetworkPanelModel

    var body: some View {
        let rows = model.visible
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Método").frame(width: 56, alignment: .leading)
                Text("Status").frame(width: 44, alignment: .leading)
                Text("Host / caminho").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tamanho").frame(width: 64, alignment: .trailing)
                Text("Tempo").frame(width: 60, alignment: .trailing)
            }
            .font(.collieMono(11, .medium)).foregroundStyle(Color.collieMuted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Rectangle().fill(Color.collieBorderSoft).frame(height: 1)
            if rows.isEmpty {
                Text(model.attached ? "Aguardando requisições…" : "Escolha um emulador e clique em Interceptar.")
                    .font(.collieUI(13)).foregroundStyle(Color.collieMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { r in FlowRowView(row: r, selected: model.selected == r.id) { Task { await model.select(flow: r.id) } } }
                        }
                    }
                    .onChange(of: rows.last?.id) { _, id in if model.selected == nil, let id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
        }
        .background(Color.collieSunken)
    }
}

private struct FlowRowView: View {
    let row: FlowRow, selected: Bool, action: () -> Void
    var body: some View {
        let s = row.summary, tone = NetworkPanelModel.tone(s)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(s.method).font(.collieMono(12, .medium)).foregroundStyle(Color.collieText).frame(width: 56, alignment: .leading)
                Text(NetworkPanelModel.statusText(s)).font(.collieMono(12, .medium)).foregroundStyle(tone.color).frame(width: 44, alignment: .leading)
                (Text(s.host).foregroundStyle(Color.collieTextSecondary) + Text(s.path).foregroundStyle(Color.collieText))
                    .font(.collieMono(12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Text(NetworkPanelModel.size(s.size)).frame(width: 64, alignment: .trailing)
                Text(NetworkPanelModel.duration(s.durationMs)).frame(width: 60, alignment: .trailing)
            }
            .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(selected ? Color.collieRaised : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(s.method) \(s.host)\(s.path), \(NetworkPanelModel.statusText(s))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The selected flow: request line, status, timings, copy buttons, then Request/Response headers and body.
private struct FlowDetailView: View {
    @ObservedObject var model: NetworkPanelModel
    @State private var tab = Tab.response
    enum Tab: String, CaseIterable { case request = "Request", response = "Response" }

    var body: some View {
        if let d = model.detail { content(d.flow, d) } else {
            Text(model.selected == nil ? "Selecione uma requisição." : "Carregando…")
                .font(.collieUI(13)).foregroundStyle(Color.collieMuted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ f: Flow, _ d: FlowDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(f.method).font(.collieMono(13, .semibold)).foregroundStyle(Color.collieText)
                Text(f.url).font(.collieMono(12)).foregroundStyle(Color.collieText).lineLimit(3).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                let tone = NetworkPanelModel.tone(f.summary)
                CollieTag([NetworkPanelModel.statusText(f.summary), f.reason].compactMap { $0 }.joined(separator: " "),
                          tone: tone == .success ? .accent : tone == .clientError ? .attention : tone == .redirect ? .secondary
                              : tone == .serverError || tone == .failed ? .danger : .neutral)
                CollieTag(f.httpVersion, tone: .neutral)
                Text(Self.timing(f)).font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1)
            }
            HStack(spacing: 8) {
                Button("Copiar URL") { model.copyURL() }.buttonStyle(CollieButtonStyle(.quiet)).accessibilityLabel("Copiar URL")
                Button("Copiar como cURL") { Task { await model.copyCurl() } }.buttonStyle(CollieButtonStyle(.secondary))
                    .accessibilityLabel("Copiar como cURL")
                Spacer()
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200).accessibilityLabel("Request ou Response")
            }
            if case .failed(let m) = f.state { Text(m).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            let (headers, body, text, preview) = tab == .request ? (f.reqHeaders, f.reqBody, d.reqText, d.reqPreview) : (f.resHeaders, f.resBody, d.resText, d.resPreview)
            // ponytail: ~21 pt per header line; a value that wraps scrolls inside the cap
            ScrollView { HeadersTable(headers: headers).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: min(max(CGFloat(headers.count), 1) * 21, 160))
            BodyPane(captured: body, preview: preview) { if let s = NetworkPanelModel.fullBody(body, text: text) { NetworkPanelModel.copy(s) } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "início 14:02:11 · TTFB 120 ms · total 340 ms".
    static func timing(_ f: Flow) -> String {
        let t = f.timing
        let ms = { (d: Date?) in d.map { NetworkPanelModel.duration(Int(($0.timeIntervalSince(t.start) * 1000).rounded())) } }
        return ["início " + t.start.formatted(date: .omitted, time: .standard), ms(t.ttfb).map { "TTFB \($0)" }, ms(t.end).map { "total \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct HeadersTable: View {
    let headers: [Header]
    var body: some View {
        if headers.isEmpty { Text("Sem headers").font(.collieUI(12)).foregroundStyle(Color.collieMuted) } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(headers.indices, id: \.self) { i in
                    GridRow {
                        Text(headers[i].name).foregroundStyle(Color.collieTextSecondary)
                        Text(headers[i].value).foregroundStyle(Color.collieText)
                    }
                }
            }
            .font(.collieMono(12)).textSelection(.enabled)
        }
    }
}

private struct BodyPane: View {
    let captured: Body?, preview: BodyPreview, copy: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let b = captured, b.truncated {
                Label("Corpo truncado: \(NetworkPanelModel.size(b.data.count)) de \(NetworkPanelModel.size(b.size)) capturados.",
                      systemImage: "scissors").font(.collieUI(12)).foregroundStyle(Color.collieAttention)
            }
            if preview.view != .empty {
                HStack(spacing: 8) {
                    if preview.isPartial {
                        Text("Mostrando \(NetworkPanelModel.size(preview.shown)) de \(NetworkPanelModel.size(preview.total))")
                            .font(.collieUI(12)).foregroundStyle(Color.collieAttention)
                    }
                    Spacer()
                    Button("Copiar body", action: copy).buttonStyle(CollieButtonStyle(.quiet)).accessibilityLabel("Copiar body inteiro")
                }
            }
            switch preview.view {
            case .empty: Text("Sem corpo").font(.collieUI(12)).foregroundStyle(Color.collieMuted).frame(maxHeight: .infinity, alignment: .top)
            case .text(let s): BodyText(text: s, wraps: true, label: "Corpo")
            case .hex(let s): BodyText(text: s, wraps: false, label: "Corpo em hexadecimal")
            }
        }
    }
}

/// `NSTextView`, not `Text`: SwiftUI lays out the whole string on the main thread (64 KB of hex took ~100 s in a debug
/// build); this one lays out what is on screen.
private struct BodyText: NSViewRepresentable {
    let text: String, wraps: Bool, label: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let t = scroll.documentView as! NSTextView
        t.isEditable = false; t.isSelectable = true; t.isRichText = false
        t.font = CollieFont.mono(12); t.textColor = CollieColor.text; t.backgroundColor = CollieColor.sunken
        t.textContainerInset = NSSize(width: 6, height: 8)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = !wraps
        if !wraps {
            t.isHorizontallyResizable = true; t.autoresizingMask = [.height]
            t.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            t.textContainer?.widthTracksTextView = false
            t.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let t = scroll.documentView as? NSTextView else { return }
        t.setAccessibilityLabel(label)
        if t.string != text { t.string = text; t.scroll(.zero) }
    }
}
