import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

/// The latest `ui.usage` reports, shared by the popover, the compact summary and the sidebar's USO section.
@MainActor @Observable final class UsageFeed {
    private(set) var reports: [UsageReport] = []
    private(set) var failure: String?
    private(set) var loaded = false

    func refresh(_ client: DaemonClient) async {
        do { reports = try await client.usage(); failure = nil } catch { failure = (error as? ProtocolError)?.message ?? error.localizedDescription }
        loaded = true
    }

    /// Refreshes now and every 5 min until cancelled.
    func poll(_ client: DaemonClient) async {
        while !Task.isCancelled {
            await refresh(client)
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// "41% · 12%": each provider's highest window; providers without a number are left out, nil when none has one.
    static func summary(_ reports: [UsageReport]) -> String? {
        let tops = reports.compactMap { $0.windows.compactMap(\.usedPercent).max() }
        return tops.isEmpty ? nil : tops.map { "\(Int($0.rounded()))%" }.joined(separator: " · ")
    }
}

/// One row per provider: label, a bar per window ("reinicia em 2h 10m") or the error. Refreshes on open.
/// Goes away in 1D, when it becomes a dock panel.
struct UsagePopover: View {
    let client: DaemonClient
    let feed: UsageFeed
    private var reports: [UsageReport] { feed.reports }
    private var failure: String? { feed.failure }
    private var loaded: Bool { feed.loaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure { Text(failure).foregroundStyle(Color.collieDanger).font(.collieUI(11)) }
            else if !loaded { ProgressView().controlSize(.small) }
            else if reports.isEmpty { Text("Nenhum provedor de uso configurado.").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
            ForEach(reports, id: \.providerId) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.label).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                    if let e = r.error { Text(e).font(.collieUI(11)).foregroundStyle(Color.collieAttention) }
                    ForEach(r.windows, id: \.label) { w in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(w.label).font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary)
                                Spacer()
                                Text(w.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—").font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary).monospacedDigit()
                            }
                            ProgressView(value: min(max((w.usedPercent ?? 0) / 100, 0), 1)).tint(Color.collieAccent)
                            if let at = w.resetsAt, let s = Self.resets(at) {
                                Text("reinicia em \(s)").font(.collieMono(10)).foregroundStyle(Color.collieMuted)
                            }
                        }
                    }
                }
            }
        }
        .padding(14).frame(width: 280, alignment: .leading)
        .task { await feed.refresh(client) }   // the window's feed polls every 5 min; opening refreshes now
    }

    /// "2h 10m", "35m", or nil when already past.
    static func resets(_ at: Date, now: Date = Date()) -> String? {
        let m = Int(at.timeIntervalSince(now) / 60)
        guard m > 0 else { return nil }
        let d = m / 1440, h = m % 1440 / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
    }
}
