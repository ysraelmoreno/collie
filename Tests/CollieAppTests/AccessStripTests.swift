import Testing
import Foundation
import CollieCore
@testable import CollieApp

private func card(_ i: Int, refused: Bool = false) -> SandboxDenial {
    SandboxDenial(terminal: UUID(), op: "read", path: "/x/\(i)/f", refusal: refused ? "nunca" : nil)
}

@Test func noCardsNoStrip() {
    let m = AccessStrip.Model(cards: [])
    #expect(m.kind == .none)
    #expect(m.text == "")
}

@Test func pendingText() {
    #expect(AccessStrip.Model(cards: (0..<3).map { card($0) }).text == "3 pedidos de acesso — ver")
    #expect(AccessStrip.Model(cards: [card(0)]).text == "O agente pediu acesso — ver")
}

@Test func refusedOnly() {
    let m = AccessStrip.Model(cards: [card(0, refused: true), card(1, refused: true)])
    #expect(m.kind == .refusedOnly(2))
    #expect(m.text == "2 acessos bloqueados de propósito")
}

@Test func mixedCountsGrantableOnly() {
    let m = AccessStrip.Model(cards: (0..<2).map { card($0) } + (2..<7).map { card($0, refused: true) })
    #expect(m.kind == .pending(2))
}

@Test func singularRefusedText() {
    #expect(AccessStrip.Model(cards: [card(0, refused: true)]).text == "1 acesso bloqueado de propósito")
}

@Test func mixedText() {
    #expect(AccessStrip.Model(cards: [card(0), card(1), card(2, refused: true)]).text == "2 pedidos de acesso — ver")
}

@Test @MainActor func popoverStateClose() {
    let s = AccessPopoverState(), id = UUID()
    s.open.insert(id)
    s.close(id)
    #expect(!s.open.contains(id))
}

/// Remote API slice 10: a grant made from a phone says so (Preferências → Sandbox, the node's access popover).
@Test func grantLineNamesThePhone() {
    let at = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
    let mac = SandboxGrant(path: "/x", access: .write, scope: .terminal, owner: UUID(), createdAt: at)
    var phone = mac; phone.by = .init(device: "d", deviceName: "iPhone de Ana", via: "tailscale")
    #expect(!AccessCopy.grantLine(mac).contains("liberado do"))
    #expect(AccessCopy.grantLine(phone).hasSuffix(" · liberado do iPhone de Ana (Tailscale)"), "\(AccessCopy.grantLine(phone))")
}

/// The "detecção indisponível" tag names why, and its tooltip says what is lost, what still works and how to fix it.
@Test func detectionTagSaysWhy() {
    let admin = AccessCopy.detection(reason: SandboxDetection.notAdmin)
    #expect(admin.tag == "detecção indisponível: requer conta de administrador")
    #expect(admin.help.contains("cartões de liberação") && admin.help.contains("continua protegendo")
            && admin.help.contains("collie access request") && admin.help.contains("administrador"))
    #expect(admin.help.contains("não tenta de novo"))
    let died = AccessCopy.detection(reason: "log stream parou: x")
    #expect(died.tag == "detecção indisponível: log stream parou: x" && died.help.contains("tentando de novo"))
    #expect(AccessCopy.detection(reason: nil).tag == "detecção indisponível")   // a daemon that predates the reason
}

/// Not admin: no tag on the bar (the reason lives in the popover and Preferências), one toast ever, until detection
/// comes back (then the key clears, so losing admin again explains again). The other reasons keep the tag, no toast.
@Test func notAdminToastsOnceAndHidesTag() {
    let d = UserDefaults(suiteName: "test.\(UUID())")!
    #expect(!AccessCopy.showsDetectionTag(detection: false, reason: SandboxDetection.notAdmin))
    #expect(AccessCopy.showsDetectionTag(detection: false, reason: "log stream parou: x"))
    #expect(AccessCopy.showsDetectionTag(detection: false, reason: nil))
    #expect(!AccessCopy.showsDetectionTag(detection: true, reason: nil) && !AccessCopy.showsDetectionTag(detection: nil, reason: nil))

    let t = AccessCopy.notAdminToast(detection: false, reason: SandboxDetection.notAdmin, defaults: d)
    #expect(t != nil && t!.contains("cartões") && t!.contains("continua protegendo") && t!.contains("collie access request")
            && t!.contains("administrador") && t!.contains("entre de novo na sessão"))
    #expect(d.bool(forKey: AccessCopy.notAdminToastKey))
    #expect(AccessCopy.notAdminToast(detection: false, reason: SandboxDetection.notAdmin, defaults: d) == nil)   // once
    #expect(AccessCopy.notAdminToast(detection: false, reason: "log stream parou: x", defaults: d) == nil)
    #expect(AccessCopy.notAdminToast(detection: nil, reason: nil, defaults: d) == nil && d.bool(forKey: AccessCopy.notAdminToastKey))
    #expect(AccessCopy.notAdminToast(detection: true, reason: nil, defaults: d) == nil)   // became admin: key cleared
    #expect(!d.bool(forKey: AccessCopy.notAdminToastKey))
    #expect(AccessCopy.notAdminToast(detection: false, reason: SandboxDetection.notAdmin, defaults: d) != nil)
}
