import SwiftUI
import AppKit
import CollieTheme
import CollieCore
import CollieClient
import CollieProtocol

/// The app side of an update (spec 2026-11-17 §4.2): mount the daemon's verified dmg, copy and check the new app into a
/// sibling (`AppUpdateSwap.prepare`), swap by rename, optionally restart the service, relaunch. Only reached through the
/// install sheet or "Instalar ao sair"; never in tests (hdiutil, the real bundle, launchd).
enum UpdateInstaller {
    static var app: URL { Bundle.main.bundleURL }
    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    static func swapper() -> AppUpdateSwap {
        AppUpdateSwap(app: app, mount: AppUpdateSwap.hdiutilMount, freeSpace: freeSpace, defaults: .standard)
    }

    static func freeSpace(_ path: String) -> Int64? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Why this app can't update itself (checks its own signature: off the main thread).
    static func refusal() async -> AppUpdateSwap.Refusal? {
        let tcc = Config.tccWarning != nil
        return await Task.detached { swapper().destinationRefusal(tccWarning: tcc) }.value
    }

    static func prepare(dmg: String, available a: UpdateStatus.Available) async throws(AppUpdateSwap.Refusal) -> URL {
        guard let m = a.manifest else { throw .badVersion(a.version) }   // the daemon's checked manifest, strictly decoded again
        let r = await Task.detached { () -> Result<URL, AppUpdateSwap.Refusal> in
            do throws(AppUpdateSwap.Refusal) {
                return .success(try swapper().prepare(dmg: URL(fileURLWithPath: dmg), manifest: m,
                                                      system: ProcessInfo.processInfo.operatingSystemVersion))
            } catch { return .failure(error) }
        }.value
        return try r.get()
    }

    /// Swap, restart the service when asked, relaunch through LaunchServices and quit.
    @MainActor static func installNow(prepared: URL, version: String, restartService: Bool) async throws(AppUpdateSwap.Refusal) {
        try swapper().swap(prepared: prepared)
        let d = UserDefaults.standard
        d.set(version, forKey: UpdateModel.justUpdatedKey)
        d.set(restartService, forKey: UpdateModel.restartedKey)
        if restartService {
            let label = Config.label
            _ = await Task.detached { try? DaemonLauncher.restart(label: label) }.value
        }
        guard AppUpdateSwap.spawnRelauncher(app: app) else { throw .swapFailed(tr("não foi possível reabrir o Collie; abra-o de novo", "couldn't reopen Collie; open it again")) }
        NSApp.terminate(nil)
    }

    /// "Instalar ao sair": the sibling is ready now; quitting only swaps (never restarts the service, never relaunches).
    static func installOnQuitIfPending() {
        let d = UserDefaults.standard
        guard let p = d.string(forKey: UpdateModel.onQuitKey) else { return }
        d.removeObject(forKey: UpdateModel.onQuitKey)
        let version = AppUpdateSwap.version(URL(fileURLWithPath: p))
        do throws(AppUpdateSwap.Refusal) {
            try swapper().swap(prepared: URL(fileURLWithPath: p))
            d.set(version, forKey: UpdateModel.justUpdatedKey)
            d.set(false, forKey: UpdateModel.restartedKey)
        } catch {}
    }

    @MainActor static func rollback() throws(AppUpdateSwap.Refusal) {
        let previous = UserDefaults.standard.string(forKey: AppUpdateSwap.previousVersionKey)
        try swapper().rollback()
        UserDefaults.standard.set(previous, forKey: UpdateModel.justUpdatedKey)
        UserDefaults.standard.set(false, forKey: UpdateModel.restartedKey)
        guard AppUpdateSwap.spawnRelauncher(app: app) else { throw .swapFailed(tr("não foi possível reabrir o Collie; abra-o de novo", "couldn't reopen Collie; open it again")) }
        NSApp.terminate(nil)
    }

    static var previousVersion: String? {
        let d = UserDefaults.standard
        guard let p = d.string(forKey: AppUpdateSwap.previousKey), FileManager.default.fileExists(atPath: p) else { return nil }
        return d.string(forKey: AppUpdateSwap.previousVersionKey)
    }
}

/// The install sheet (spec §3): how many terminals and agents run now, "Atualizar só o app" by default, "Atualizar e
/// reiniciar o serviço" waits for busy agents, "Instalar ao sair" prepares now and swaps on quit.
struct UpdateInstallSheet: View {
    let client: DaemonClient
    let status: UpdateStatus
    let engine: String?
    let done: () -> Void
    @State private var restart = false
    @State private var working = false
    @State private var waiting = false
    @State private var error: String?

    var body: some View {
        let act = UpdateModel.activity(terminals: client.terminals, badges: client.badges)
        let t = UpdateModel.sheet(version: status.available?.version ?? "?", open: act.open, busy: act.busy, restart: restart, engine: engine)
        VStack(alignment: .leading, spacing: 12) {
            Text(t.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
            Text(t.intro).font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
            if !t.options.isEmpty {
                Picker("", selection: $restart) {
                    Text(t.options[0]).tag(false)
                    Text(t.options[1]).tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden().disabled(working)
                Text(t.optionNotes[restart ? 1 : 0]).font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = t.engine { Text(e).font(.collieMono(12)).foregroundStyle(Color.collieAttention).fixedSize(horizontal: false, vertical: true) }
            if waiting, let w = t.waiting { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(w).font(.collieMono(12)) } }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(tr("Cancelar", "Cancel")) { waiting = false; done() }.buttonStyle(CollieButtonStyle(.quiet))
                Button(t.onQuit) { onQuit() }.buttonStyle(CollieButtonStyle(.quiet)).disabled(working)
                Button(t.primary) { install() }.buttonStyle(CollieButtonStyle(.primary)).disabled(working)
            }
        }
        .padding(20).frame(width: 520).background(Color.collieBackground)
    }

    private func prepared() async -> URL? {
        guard let dmg = status.staged, let a = status.available else { error = tr("o download ainda não terminou", "the download hasn't finished yet"); return nil }
        do { return try await UpdateInstaller.prepare(dmg: dmg, available: a) }
        catch { self.error = UpdateModel.text(error); return nil }
    }

    private func install() {
        working = true; error = nil
        Task {
            defer { working = false }
            guard let p = await prepared(), let v = status.available?.version else { return }
            if restart {   // never close a working agent without waiting for it (spec §3)
                waiting = true
                while waiting, !UpdateModel.activity(terminals: client.terminals, badges: client.badges).busy.isEmpty {
                    try? await Task.sleep(for: .seconds(5))
                }
                guard waiting else { try? FileManager.default.removeItem(at: p.deletingLastPathComponent()); return }
                waiting = false
            }
            do throws(AppUpdateSwap.Refusal) { try await UpdateInstaller.installNow(prepared: p, version: v, restartService: restart) }
            catch { self.error = UpdateModel.text(error) }
        }
    }

    private func onQuit() {
        working = true; error = nil
        Task {
            defer { working = false }
            guard let p = await prepared() else { return }
            UserDefaults.standard.set(p.path, forKey: UpdateModel.onQuitKey)
            done()
        }
    }
}

/// The app's ephemeral notice (bottom right, over the window): text and its buttons. Update and detection notices share it.
struct NoticeCard<Actions: View>: View {
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.collieUI(13)).foregroundStyle(Color.collieText).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
            actions
        }
        .padding(12).background(Color.collieSurface, in: .rect(cornerRadius: 8)).padding(16)
    }
}

/// What the app does around updates outside Preferências: one check at launch, one notification per version ready,
/// the "Atualizado para X" notice (with the engine's download when the new pin blocks the Design panel), the previous
/// bundle's healthy-launch count and the "Instalar ao sair" swap.
struct UpdateLaunchHost: ViewModifier {
    let client: DaemonClient
    let bundledBuild: String?
    @State private var notice: String?
    @State private var engineBlocked = false
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) { if let notice { noticeView(notice) } }
            .task(id: client.state == .connected) { if client.state == .connected { await launched() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                UpdateInstaller.installOnQuitIfPending()
            }
    }

    private func noticeView(_ text: String) -> some View {
        NoticeCard(text: text) {
            if engineBlocked {
                Button(tr("Baixar motor agora", "Download engine now")) {
                    Task { _ = try? await client.adminCall("design.engine.install", [:]) }
                    UserDefaults.standard.set(PreferencePage.desenho.rawValue, forKey: PreferencePage.requestKey)
                    NotificationCenter.default.post(name: Notification.Name("collieOpenPreferences"), object: PreferencePage.desenho.rawValue)
                    notice = nil
                }.buttonStyle(CollieButtonStyle(.primary))
            }
            Button("OK") { notice = nil }.buttonStyle(CollieButtonStyle(.quiet))
        }
    }

    private func launched() async {
        let d = UserDefaults.standard, swap = UpdateInstaller.swapper()
        d.removeObject(forKey: UpdateModel.onQuitKey)   // one left by a session that never quit cleanly: its sibling goes below
        AppUpdateSwap.cleanupOrphans(parent: UpdateInstaller.app.deletingLastPathComponent(),
                                     keep: d.string(forKey: AppUpdateSwap.previousKey).map { URL(fileURLWithPath: $0) })
        if !counted {   // healthy: connected, and after a service restart the daemon runs this bundle's build
            counted = true
            let restarted = d.bool(forKey: UpdateModel.restartedKey)
            swap.launched(healthy: !restarted || (bundledBuild != nil && client.daemonBuild == bundledBuild))
        }
        if let n = UpdateModel.updatedNotice(justUpdated: d.string(forKey: UpdateModel.justUpdatedKey), running: UpdateInstaller.installedVersion) {
            let engine = try? await client.adminCall("design.engine.status", [:])
            engineBlocked = engine.flatMap(DesignEngineStatus.from)?.state == "needsUpdate"
            notice = n
        }
        d.removeObject(forKey: UpdateModel.justUpdatedKey)
        guard await UpdateInstaller.refusal() != .localBuild else { return }   // a local build never checks
        _ = try? await client.adminCall("app.update.check", ["installed": .string(UpdateInstaller.installedVersion)], timeout: 90)
        while client.state == .connected, !Task.isCancelled {
            if let s = (try? await client.adminCall("app.update.status", [:])).flatMap(UpdateStatus.from),
               let v = UpdateModel.shouldNotify(s, lastNotified: d.string(forKey: UpdateModel.notifiedKey)) {
                Notifier.shared.notify(UUID(), title: tr("Collie \(v) pronto para instalar", "Collie \(v) ready to install"), body: tr("Preferências › Atualizações", "Preferences › Updates"))
                d.set(v, forKey: UpdateModel.notifiedKey)
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }
}
