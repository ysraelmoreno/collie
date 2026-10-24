import AppKit
@preconcurrency import UserNotifications
import os
import CollieCore

/// At most one access notification per terminal per 30 s (a denial storm becomes one, then the strip's count).
struct AccessNotifyGate {
    static let window: TimeInterval = 30
    private var last: [UUID: Date] = [:]
    mutating func shouldPost(terminal: UUID, at now: Date = Date()) -> Bool {
        if let t = last[terminal], now.timeIntervalSince(t) < Self.window { return false }
        last[terminal] = now
        return true
    }
}

/// macOS notification when a terminal needs attention; clicking it calls `onFocus` with the terminal id.
/// Never throws or blocks: an unbundled run, a denied permission or a failed post is only logged.
@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let log = Logger(subsystem: "dev.collie.app", category: "notify")
    static let shared = Notifier()
    var onFocus: ((UUID) -> Void)?
    // UNUserNotificationCenter traps without an app bundle (`swift run`).
    private let center: UNUserNotificationCenter? = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    private var asked = false

    override init() {
        super.init()
        center?.delegate = self   // set at launch so a click that relaunches the app is delivered
    }

    private var accessGate = AccessNotifyGate()
    /// One per new card, throttled per terminal. Body: the verb and the path's last two components only.
    func notifyAccess(_ d: SandboxDenial, name: String) {
        guard accessGate.shouldPost(terminal: d.terminal) else { return }
        let tail = d.path.split(separator: "/").suffix(2).joined(separator: "/")
        notify(d.terminal, title: "\(AccessCopy.shown(name)) pediu acesso", body: "Quer \(AccessCopy.verb(d.op)) …/\(AccessCopy.shown(tail))")
    }

    func notify(_ id: UUID, name: String, reason: String) { notify(id, title: "\(name) precisa de atenção", body: reason) }

    func notify(_ id: UUID, title: String, body: String) {
        guard let center else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = ["id": id.uuidString]
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        let post: @Sendable () -> Void = { center.add(req) { err in if let err { Self.log.error("notify: \(err, privacy: .public)") } } }
        guard !asked else { return post() }
        asked = true   // once per launch; the system remembers the answer. Post after the answer: no race.
        center.requestAuthorization(options: [.alert, .sound]) { ok, err in
            if ok { post() } else { Self.log.info("notifications not authorized: \(err.map { "\($0)" } ?? "denied", privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        guard let s = r.notification.request.content.userInfo["id"] as? String, let id = UUID(uuidString: s) else { return }
        await MainActor.run {
            NSApp.activate()
            self.onFocus?(id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
