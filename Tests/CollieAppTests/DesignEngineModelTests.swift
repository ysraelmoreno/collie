import Foundation
import Testing
import CollieProtocol
@testable import CollieApp

/// Preferências › Desenho e sandbox, "Motor de design": `design.engine.status` decoded and mapped to one row.
private let br = Locale(identifier: "pt_BR")

private func status(_ state: String, installed: [String: JSONValue]? = nil, reinstall: Bool? = nil,
                    pinned: (String, Double)? = ("0.8.0-c1", 53_200_000), job: [String: JSONValue]? = nil) -> DesignEngineStatus {
    var o: [String: JSONValue] = ["state": .string(state)]
    if let installed { o["installed"] = .object(installed) }
    if let reinstall { o["reinstall"] = .bool(reinstall) }
    if let pinned { o["pinned"] = .object(["version": .string(pinned.0), "size": .number(pinned.1)]) }
    if let job { o["job"] = .object(job) }
    return DesignEngineStatus.from(.object(o))!
}

@Test func rowAbsentShowsDownloadSize() {
    let s = status("absent", pinned: ("0.7.0-c1", 51_400_000))
    #expect(DesignEngineStatus.row(s, locale: br) == .absent(download: "51,4 MB"))
    #expect(DesignEngineStatus.row(s, locale: br).button == "Baixar (51,4 MB)")
    #expect(DesignEngineStatus.from(.string("x")) == nil)
}

@Test func rowDownloadingProgress() {
    let s = status("absent", job: ["phase": .string("downloading"), "bytes": .number(33_100_000), "total": .number(51_400_000)])
    #expect(DesignEngineStatus.row(s, locale: br) == .downloading(done: "33,1 MB", total: "51,4 MB"))
    #expect(DesignEngineStatus.row(status("absent", job: ["phase": .string("verifying")]), locale: br) == .verifying)
    #expect(DesignEngineStatus.row(status("absent", job: ["phase": .string("installing")]), locale: br) == .verifying)
    // a finished or cancelled job is history: the row is the engine's state
    #expect(DesignEngineStatus.row(status("absent", job: ["phase": .string("cancelled")]), locale: br) == .absent(download: "53,2 MB"))
}

@Test func rowBundledHasNoRemove() {
    let bundle = DesignEngineStatus.row(status("installed", installed: ["version": .string("0.7.0"), "source": .string("bundle")]), locale: br)
    #expect(bundle == .installed(version: "0.7.0", bundled: true))
    #expect(bundle.text == "v0.7.0 · embutido no app")
    #expect(!bundle.canRemove)
    let app = DesignEngineStatus.row(status("installed", installed: ["version": .string("0.7.0-c1"), "source": .string("appSupport")]), locale: br)
    #expect(app == .installed(version: "0.7.0-c1", bundled: false))
    #expect(app.text == "v0.7.0-c1 · Application Support")
    #expect(app.canRemove)
}

@Test func rowNeedsUpdate() {
    let r = DesignEngineStatus.row(status("needsUpdate", installed: ["version": .string("0.7.0-c1"), "source": .string("appSupport")], reinstall: false), locale: br)
    #expect(r == .needsUpdate(installed: "0.7.0-c1", pinned: "0.8.0-c1", download: "53,2 MB", reinstall: false))
    #expect(r.button == "Atualizar (53,2 MB)")
    #expect(r.text == "Motor v0.7.0-c1 desatualizado: este Collie usa v0.8.0-c1. O painel Design fica indisponível até atualizar.")
}

@Test func rowReinstall() {
    let r = DesignEngineStatus.row(status("needsUpdate", installed: ["version": .string("0.9.0-c1"), "source": .string("appSupport")], reinstall: true), locale: br)
    #expect(r.button == "Reinstalar (53,2 MB)")
    #expect(r.text == "Motor v0.9.0-c1 não é o deste Collie (v0.8.0-c1).")
}

@Test func needsUpdateAllowsRemove() {
    #expect(DesignEngineStatus.row(status("needsUpdate", installed: ["source": .string("appSupport")], reinstall: true), locale: br).canRemove)
    #expect(!DesignEngineStatus.row(status("absent"), locale: br).canRemove)
}

@Test func rowFailedCarriesMessage() {
    let r = DesignEngineStatus.row(status("absent", job: ["phase": .string("failed"), "error": .string("Espaço insuficiente")]), locale: br)
    #expect(r == .failed("Espaço insuficiente"))
    #expect(r.text == "Falhou: Espaço insuficiente")
    #expect(r.button == "Tentar de novo")
}

@Test func pollIsOneSecondWithJobThreeWithout() {
    #expect(DesignEngineStatus.pollInterval(nil) == .seconds(3))
    #expect(DesignEngineStatus.pollInterval(status("absent")) == .seconds(3))
    #expect(DesignEngineStatus.pollInterval(status("absent", job: ["phase": .string("downloading")])) == .seconds(1))
    #expect(DesignEngineStatus.pollInterval(status("absent", job: ["phase": .string("verifying")])) == .seconds(1))
    #expect(DesignEngineStatus.pollInterval(status("installed", job: ["phase": .string("done")])) == .seconds(3))
    #expect(DesignEngineStatus.pollInterval(status("absent", job: ["phase": .string("failed")])) == .seconds(3))
}
