import AppKit
import Sparkle
import CollieCore

/// The app's updater (spec 2026-11-25): Sparkle checks, downloads, verifies (EdDSA + Apple team), installs (asking for the
/// admin password when `/Applications` needs it) and relaunches. This wrapper only decides *when* it may relaunch: while an
/// agent is working the relaunch waits for the owner ("Atualizar mesmo assim" / "Depois"), and a build that is not signed by
/// the team (a local build) never starts it.
@MainActor final class SparkleUpdater: NSObject, ObservableObject {
    static let shared = SparkleUpdater()

    /// The agents working now (names); set once the daemon client exists. Empty until then.
    var busy: @MainActor () -> [String]
    private var controller: SPUStandardUpdaterController?
    private var held: (() -> Void)?

    init(busy: @escaping @MainActor () -> [String] = { [] }, disabled: Bool = !SparkleUpdater.signedByTeam()) {
        self.busy = busy
        super.init()
        // after `super.init`: the controller takes `self` as its delegate (the relaunch policy below)
        guard !disabled else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller?.updater.updateCheckInterval = 12 * 3600
    }

    /// Starts the schedule (idempotent). A disabled wrapper starts nothing.
    func start() {
        guard let controller, !controller.updater.sessionInProgress else { return }
        try? controller.updater.start()
    }

    nonisolated static func signedByTeam() -> Bool {
        CodeSignature.appAndHelpers(Bundle.main.bundleURL, teamId: CodeSignature.team)
    }

    /// False for a build the team did not sign: no updater exists. (`canCheck` is also false while a check runs.)
    var isEnabled: Bool { controller != nil }
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    func checkNow() { controller?.checkForUpdates(nil) }
    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: relaunch policy

    nonisolated static func shouldPostpone(busy: [String]) -> Bool { !busy.isEmpty }

    /// Keeps the relaunch `go` until nobody is working (`releaseIfIdle`, called when the agents' badges change) or the owner insists.
    func hold(_ go: @escaping () -> Void) { held = go }
    func releaseIfIdle() { if held != nil, !Self.shouldPostpone(busy: busy()) { releaseNow() } }
    func releaseNow() {
        let go = held; held = nil
        go?()
    }
}

/// Sparkle calls its delegate on the main thread; `@preconcurrency` makes that the checked isolation.
extension SparkleUpdater: @preconcurrency SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let working = busy()
        guard Self.shouldPostpone(busy: working) else { return false }
        hold(installHandler)
        let a = NSAlert()
        a.messageText = "Collie \(item.displayVersionString) pronto para instalar"
        a.informativeText = UpdateModel.busyNotice(version: item.displayVersionString, busy: working)
        a.addButton(withTitle: "Atualizar mesmo assim")
        a.addButton(withTitle: "Depois")
        if a.runModal() == .alertFirstButtonReturn { releaseNow() }
        return true
    }
}
