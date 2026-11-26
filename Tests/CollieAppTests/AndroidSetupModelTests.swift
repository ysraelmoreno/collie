import Testing
import CollieCore
import Foundation
import CollieProtocol
@testable import CollieApp

private func item(_ id: String, _ state: String, _ detail: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = ["id": .string(id), "state": .string(state)]
    if let detail { o["detail"] = .string(detail) }
    return .object(o)
}
private let ids = ["java", "cmdline-tools", "platform-tools", "emulator", "image"]
private func status(_ states: [String], needs: String, job: JSONValue? = nil, lite: Bool = false) -> AndroidSetupStatus {
    var o: [String: JSONValue] = ["sdk": .object(["path": .string("/sdk"), "source": .string("collie")]),
                                  "items": .array(zip(ids, states).map { item($0, $1) }), "needs": .string(needs), "lite": .bool(lite)]
    if let job { o["job"] = job }
    return AndroidSetupStatus.from(.object(o))!
}
private func job(_ phase: String, error: String? = nil) -> JSONValue {
    var o: [String: JSONValue] = ["phase": .string(phase)]
    if let error { o["error"] = .string(error) }
    return .object(o)
}
private let lic = [AndroidLicense(id: "a", title: "A", text: "t", accepted: false)]
private let allMissing = ["missing", "missing", "missing", "missing", "missing"]
private let someOk = ["ok", "missing", "missing", "missing", "missing"]
private let allOk = ["ok", "ok", "ok", "ok", "ok"]

@Test(.appPT) func statusDecodesTheDaemonReply() {
    let v: JSONValue = .object([
        "sdk": .object(["path": .string("/sdk"), "source": .string("env")]),
        "items": .array([item("java", "ok", "17"), item("image", "installing")]),
        "needs": .string("needsLicense"), "lite": .bool(true),
        "job": .object(["phase": .string("install"), "item": .string("image"), "percent": .number(40), "bytes": .number(100), "total": .number(250)])])
    let s = AndroidSetupStatus.from(v)
    #expect(s?.sdk == .init(path: "/sdk", source: "env"))
    #expect(s?.items == [.init(id: "java", state: "ok", detail: "17"), .init(id: "image", state: "installing", detail: "")])
    #expect(s?.needs == "needsLicense" && s?.lite == true)
    #expect(s?.job == .init(phase: "install", item: "image", percent: 40, bytes: 100, total: 250, error: nil))
    #expect(AndroidSetupStatus.from(.object(["items": .array([]), "needs": .string("ready")])) == nil)
    #expect(AndroidSetupStatus.from(.object(["sdk": .object(["path": .string("/s"), "source": .string("x")]), "needs": .string("ready")])) == nil)
}

@Test(.appPT) func licensesListDecodesAndEmptyIsEmpty() {
    let o: (String) -> JSONValue = { .object(["id": .string($0), "title": .string("T\($0)"), "text": .string("x"), "accepted": .bool($0 == "b")]) }
    #expect(AndroidLicense.list(.array([o("a"), o("b")])).map(\.id) == ["a", "b"])
    #expect(AndroidLicense.list(.array([o("a"), o("b")]))[1].accepted)
    #expect(AndroidLicense.list(.array([])).isEmpty)
    #expect(AndroidLicense.list(.string("nope")).isEmpty)
}

@Test(.appPT) func deriveMatrix() {
    func d(_ s: AndroidSetupStatus, _ l: [AndroidLicense]? = nil, refused: Bool = false, busy: String? = nil) -> AndroidScreenState {
        AndroidScreenState.derive(status: s, licenses: l, refused: refused, busy: busy)
    }
    #expect(d(status(allMissing, needs: "needsPrepare")) == .nada)
    #expect(d(status(someOk, needs: "needsPrepare")) == .parcial)
    #expect(d(status(["missing", "ok", "ok", "ok", "ok"], needs: "needsPrepare")) == .parcial)
    #expect(d(status(allMissing, needs: "needsPrepare", job: job("prepare"))) == .preparando)
    #expect(d(status(["ok", "ok", "missing", "missing", "missing"], needs: "needsLicense"), lic) == .licenca)
    #expect(d(status(["ok", "ok", "missing", "missing", "missing"], needs: "needsLicense"), lic, refused: true) == .recusou)
    #expect(d(status(allOk, needs: "ready"), lic, refused: true) == .pronto)
    #expect(d(status(allMissing, needs: "needsLicense", job: job("install"))) == .instalando)
    #expect(d(status(allMissing, needs: "needsLicense", job: job("install")), busy: "x") == .instalando)
    #expect(d(status(allMissing, needs: "needsLicense", job: job("failed", error: "sem espaço")), [AndroidLicense(id: "a", title: "A", text: "t", accepted: true)]) == .erro("sem espaço"))
    #expect(d(status(["ok", "ok", "missing", "missing", "missing"], needs: "needsLicense", job: job("failed", error: "x")), lic) == .licenca)
    #expect(d(status(["ok", "ok", "missing", "missing", "missing"], needs: "needsLicense", job: job("failed", error: "x")), lic, refused: true) == .recusou)
    #expect(d(status(allMissing, needs: "needsPrepare", job: job("cancelled"))) == .nada)
    #expect(d(status(someOk, needs: "needsPrepare", job: job("cancelled"))) == .parcial)
    #expect(d(status(["ok", "ok", "missing", "missing", "missing"], needs: "needsLicense", job: job("cancelled")), lic) == .licenca)
    #expect(d(status(someOk, needs: "needsPrepare", job: job("done"))) == .parcial)
    #expect(d(status(someOk, needs: "needsPrepare"), busy: "Android Studio") == .ocupado("Android Studio"))
    #expect(d(status(allOk, needs: "ready"), busy: "b") == .ocupado("b"))
    #expect(d(status(allOk, needs: "ready")) == .pronto)
}

@Test(.appPT) func deriveWithoutLicenseListNeverAsksForAccept() {
    func d(_ s: AndroidSetupStatus, refused: Bool = false) -> AndroidScreenState {
        AndroidScreenState.derive(status: s, licenses: [], refused: refused, busy: nil)
    }
    #expect(d(status(allMissing, needs: "needsLicense")) == .nada)
    #expect(d(status(someOk, needs: "needsLicense"), refused: true) == .parcial)
    #expect(d(status(allOk, needs: "ready")) == .pronto)
}

@Test(.appPT) func copyFormatsSizesWithTilde() {
    #expect(AndroidCopy.bytes(15 << 20) == "~15 MB")
    #expect(AndroidCopy.bytes(6 << 30) == "~6 GB")
    let s = status(["ok", "ok", "ok", "missing", "missing"], needs: "needsLicense")
    #expect(AndroidCopy.totalPending(s) == (400 << 20) + (6 << 30))
    #expect(AndroidCopy.needsFree(s) == 2 * AndroidCopy.totalPending(s))
    #expect(AndroidCopy.totalPending(status(allOk, needs: "ready")) == 0)
}

@Test(.appPT) func deriveAsksOnlyForPendingLicenses() {
    let done = [AndroidLicense(id: "a", title: "A", text: "t", accepted: true)]
    let st = status(someOk, needs: "needsLicense")
    #expect(AndroidScreenState.derive(status: st, licenses: done, refused: false, busy: nil) == .parcial)
    #expect(AndroidScreenState.derive(status: st, licenses: done, refused: true, busy: nil) == .parcial)
    #expect(AndroidScreenState.derive(status: st, licenses: done + lic, refused: false, busy: nil) == .licenca)
}

@Test(.appPT) func deriveDoneJobAndUnloadedLicenses() {
    func d(_ s: AndroidSetupStatus, _ l: [AndroidLicense]? = nil) -> AndroidScreenState {
        AndroidScreenState.derive(status: s, licenses: l, refused: false, busy: nil)
    }
    #expect(d(status(allOk, needs: "ready", job: job("done"))) == .pronto)
    #expect(d(status(someOk, needs: "needsPrepare", job: job("done"))) == .parcial)
    #expect(d(status(allMissing, needs: "needsLicense", job: job("done")), nil) == .nada)
    #expect(d(status(allOk, needs: "needsLicense"), nil) == .parcial)
}

@Test(.appPT) func statusDecodeToleratesNonFiniteNumbers() {
    let j: JSONValue = .object(["phase": .string("install"), "percent": .number(.nan), "bytes": .number(1e30), "total": .number(.infinity)])
    let s = status(allMissing, needs: "ready", job: j)
    #expect(s.job?.percent == nil && s.job?.bytes == nil && s.job?.total == nil)
}

@Test(.appPT) func labelsPerStateCopyThePreview() {
    let cases: [(AndroidScreenState, String, String)] = [
        (.nada, "Nada instalado", "Instalar"), (.parcial, "Parcial", "Instalar o que falta"),
        (.preparando, "Preparando (fase 1)", "Cancelar"), (.licenca, "Licenças do SDK do Android", "Aceitar e baixar"),
        (.instalando, "Instalando (fase 2)", "Cancelar"), (.pronto, "Tudo pronto", "Criar emulador leve"),
        (.erro("x"), "Erro", "Tentar de novo"), (.recusou, "Licenças recusadas.", "Rever licenças"),
        (.ocupado("busy: y"), "Outro processo está usando o SDK.", "Tentar de novo"),
    ]
    for (s, title, button) in cases {
        let l = AndroidCopy.label(for: s)
        #expect(l.title == title, "\(s)"); #expect(l.button == button, "\(s)")
    }
    #expect(AndroidCopy.notice == "Ao instalar, você aceita os termos do Android SDK")
}

@Test(.appPT) func acceptIdsSendsOnlyCheckedPending() {
    let two = [AndroidLicense(id: "a", title: "", text: "", accepted: false), AndroidLicense(id: "b", title: "", text: "", accepted: true),
               AndroidLicense(id: "c", title: "", text: "", accepted: false)]
    #expect(AndroidCopy.acceptIds(licenses: two, checked: false) == [])
    #expect(AndroidCopy.acceptIds(licenses: two, checked: true) == ["a", "c"])
    #expect(AndroidCopy.acceptIds(licenses: [], checked: true) == [])
}
