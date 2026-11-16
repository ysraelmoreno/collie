import Testing
import Foundation
import Darwin
import CollieProtocol
@testable import CollieDaemonKit

private let fakeServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-figcraft-server.sh")
private let realServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("vendor/figcraft/bin/figcraft-server")

private struct Fixture {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-figsrv-\(UUID().uuidString)")
    /// Away from the default range so a real Collie on this machine is never in the way.
    let port = UInt16.random(in: 52000...58000)
    var log: URL { dir.appendingPathComponent("server.log") }
    var dataDir: URL { dir.appendingPathComponent("data") }
    init() { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func server(_ env: [String: String] = [:], binary: URL = fakeServer) -> FigcraftServer {
        let e = engineDir(binary, in: dir)
        return FigcraftServer(engine: { FigcraftEngine(dir: e, version: nil, source: .env) }, dataDir: dataDir,
                              runDir: dir.appendingPathComponent("run"), port: port,
                              env: env.merging(["COLLIE_FAKE_FIG_LOG": log.path]) { a, _ in a })
    }
    /// A server whose engine, state and signature check the test controls through `box`.
    func server(_ box: EngineBox) -> FigcraftServer {
        FigcraftServer(engine: { box.engine }, state: { box.state }, verify: { _ in box.signed }, dataDir: dataDir,
                       runDir: dir.appendingPathComponent("run"), port: port, env: ["COLLIE_FAKE_FIG_LOG": log.path])
    }
    /// One line per server start: "<pid> <args>".
    var starts: [[String]] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
    }
}

/// An engine dir `<in>/engine-<uuid>/bin/figcraft-server` -> `binary` (a missing `binary`: no link, so not executable).
func engineDir(_ binary: URL, in parent: URL) -> URL {
    let d = parent.appendingPathComponent("engine-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: d.appendingPathComponent("bin"), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: binary.path) {
        try? FileManager.default.createSymbolicLink(at: d.appendingPathComponent("bin/figcraft-server"), withDestinationURL: binary)
    }
    return d
}

/// What a test's server resolves, mutable while it runs.
final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _engine: FigcraftEngine?, _state: EngineState = .absent, _signed = true
    var engine: FigcraftEngine? { get { lock.withLock { _engine } } set { lock.withLock { _engine = newValue } } }
    var state: EngineState { get { lock.withLock { _state } } set { lock.withLock { _state = newValue } } }
    var signed: Bool { get { lock.withLock { _signed } } set { lock.withLock { _signed = newValue } } }
    init(_ dir: URL? = nil) { _engine = dir.map { FigcraftEngine(dir: $0, version: nil, source: .appSupport) } }
}

/// A loopback listener holding `port` until closed (`SO_REUSEADDR`: a just-stopped server's TIME_WAIT is no obstacle).
func occupy(_ port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    #expect(ok == 0 && listen(fd, 1) == 0)
    return fd
}

private func healthy(_ port: UInt16) async -> Bool {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, timeoutInterval: 1)
    req.setValue("close", forHTTPHeaderField: "Connection")   // keep-alive would hold the real server's shutdown
    guard let (_, r) = try? await URLSession.shared.data(for: req) else { return false }
    return (r as? HTTPURLResponse)?.statusCode == 200
}

@Suite(.serialized) struct FigcraftServerTests {
    @Test func serverBindsLoopbackOnly() async throws {
        let fx = Fixture(), s = fx.server()
        let (url, key) = try await s.ensureRunning()
        #expect(url == "ws://127.0.0.1:\(fx.port)/?key=fakeKey_123-abc" && key == "fakeKey_123-abc")
        let args = fx.starts.first ?? []
        #expect(args.contains("--listen") && args.contains("127.0.0.1:\(fx.port)"), "\(args)")
        #expect(args.contains("--data") && args.contains(fx.dataDir.path), "\(args)")
        // design files up to 512 MiB (the server's own default is 64; the app opens up to 1 GiB)
        let cfg = fx.dataDir.appendingPathComponent("collie-server.toml")
        #expect(args.contains("--config") && args.contains(cfg.path), "\(args)")
        #expect(try String(contentsOf: cfg, encoding: .utf8).contains("max_file_mb = 512"))
        #expect(await healthy(fx.port))
        // already up: no second start
        _ = try await s.ensureRunning()
        #expect(fx.starts.count == 1)
        await s.stop()
        #expect(await waitFor(5) { await !healthy(fx.port) })
    }

    @Test func keyNotCopied() async throws {
        let fx = Fixture(), s = fx.server()
        let f = fx.dataDir.appendingPathComponent("key")
        try FileManager.default.createDirectory(at: fx.dataDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: f)   // an older build's copy goes
        _ = try await s.ensureRunning()
        await s.stop()
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func portFallsThroughWhenBusy() async throws {
        let fx = Fixture()
        let held = occupy(fx.port)
        defer { close(held) }
        let s = fx.server()
        let (url, _) = try await s.ensureRunning()
        #expect(url.hasPrefix("ws://127.0.0.1:\(fx.port + 1)/"), "\(url)")
        #expect(fx.starts.first?.contains("127.0.0.1:\(fx.port + 1)") == true)
        await s.stop()
    }

    @Test func serverRestartsAfterCrash() async throws {
        let fx = Fixture(), s = fx.server(["COLLIE_FAKE_FIG_SERVER_DIE": "1"])
        _ = try await s.ensureRunning()
        let first = fx.starts.first?.first
        #expect(await waitFor(5) { await !healthy(fx.port) })
        try await Task.sleep(for: .milliseconds(300))   // the exit reaches the actor
        // inside the 1 s backoff window: refused at once, nothing started
        do { _ = try await s.ensureRunning(); Issue.record("restarted inside the backoff window") } catch {
            #expect(error == ProtocolError(code: .unavailable, message: "design engine restarting, retry in 1s"))
        }
        #expect(fx.starts.count == 1)
        // back on its own once the backoff is over (no further call), on the same port
        #expect(await waitFor(5) { await healthy(fx.port) })
        #expect(fx.starts.count == 2 && fx.starts.last?.first != first, "\(fx.starts)")
        // it dies again (a 2 s backoff now): stop cancels the restart
        #expect(await waitFor(5) { await !healthy(fx.port) })
        await s.stop()
        try await Task.sleep(for: .seconds(3))
        #expect(fx.starts.count == 2, "\(fx.starts)")
    }

    @Test func portKeptAcrossDaemons() async throws {
        let fx = Fixture()
        let held = occupy(fx.port)
        let s = fx.server()
        _ = try await s.ensureRunning()
        await s.stop()
        close(held)   // the base port is free again: a new daemon still prefers the last one
        let s2 = fx.server()
        let (url, _) = try await s2.ensureRunning()
        #expect(url.hasPrefix("ws://127.0.0.1:\(fx.port + 1)/"), "\(url)")
        await s2.stop()
    }

    @Test func restartKeepsItsPort() async throws {
        let fx = Fixture()
        let held = occupy(fx.port)
        let s = fx.server(["COLLIE_FAKE_FIG_SERVER_DIE": "1"])
        let (url, _) = try await s.ensureRunning()
        #expect(url.hasPrefix("ws://127.0.0.1:\(fx.port + 1)/"), "\(url)")
        close(held)   // the base port is free again, but the restart must not move
        #expect(await waitFor(5) { await !healthy(fx.port + 1) })
        try await Task.sleep(for: .milliseconds(1300))   // exit reported and the 1 s backoff over
        let (again, _) = try await s.ensureRunning()
        #expect(again.hasPrefix("ws://127.0.0.1:\(fx.port + 1)/") && fx.starts.count == 2, "\(again) \(fx.starts)")
        await s.stop()
    }

    @Test func stopCancelsAStartInFlight() async throws {
        let fx = Fixture(), s = fx.server(["COLLIE_FAKE_FIG_SERVER_HANG": "1"])
        let pending = Task { () async -> ProtocolError? in
            do { _ = try await s.ensureRunning(); return nil } catch { return error as? ProtocolError }
        }
        #expect(await waitFor(5) { fx.starts.count == 1 })
        let t0 = ContinuousClock.now
        await s.stop()
        let e = await pending.value
        #expect(e == ProtocolError(code: .unavailable, message: "design engine stopped"), "\(String(describing: e))")
        #expect(ContinuousClock.now - t0 < .seconds(4))   // not the 10 s healthz wait
    }

    @Test func missingEngineIsUnavailable() async throws {
        let fx = Fixture(), s = fx.server(binary: fx.dir.appendingPathComponent("nope/bin/figcraft-server"))
        do { _ = try await s.ensureRunning(); Issue.record("started a missing binary") } catch {
            #expect(error == FigcraftServer.unavailable(.absent, admin: true))
        }
    }

    @Test func daemonWithoutEngineReportsNotInstalled() async throws {
        try await withDaemon { d, _ in
            do { _ = try await d.router.figcraft.ensureRunning(); Issue.record("started without an engine") } catch {
                #expect(error as? ProtocolError == FigcraftServer.unavailable(.absent, admin: true))
            }
            await d.stop()
        }
    }

    @Test func missingEngineSaysNotInstalledForAdmin() async throws {
        let fx = Fixture(), s = fx.server(EngineBox())
        do { _ = try await s.ensureRunning(); Issue.record("started") } catch {
            #expect(error == ProtocolError(code: .unavailable, message:
                "Motor de design não instalado. Baixe em Preferências › Desenho e sandbox (collie design engine install)"))
        }
        #expect(fx.starts.isEmpty)
    }

    @Test func missingEngineSaysNotInstalledForTerminal() {
        let e = FigcraftServer.forTerminal(FigcraftServer.unavailable(.absent, admin: true))
        #expect(e == ProtocolError(code: .unavailable, message:
            "Motor de design não instalado: peça ao usuário para baixá-lo em Preferências › Desenho e sandbox do Collie."))
        let other = ProtocolError(code: .unavailable, message: "design engine busy")
        #expect(FigcraftServer.forTerminal(other) == other)
    }

    @Test func staleEngineSaysOutdatedForAdmin() async throws {
        let fx = Fixture(), box = EngineBox()
        box.state = .needsUpdate(installed: "0.7.0-c1", pinned: "0.8.0-c1", reinstall: false)
        do { _ = try await fx.server(box).ensureRunning(); Issue.record("started") } catch {
            #expect(error == ProtocolError(code: .unavailable, message:
                "Motor de design desatualizado. Atualize em Preferências › Desenho e sandbox (collie design engine install)"))
        }
        #expect(fx.starts.isEmpty)
    }

    @Test func staleEngineSaysOutdatedForTerminal() {
        let st = EngineState.needsUpdate(installed: nil, pinned: "0.8.0-c1", reinstall: true)
        #expect(FigcraftServer.forTerminal(FigcraftServer.unavailable(st, admin: true)) == ProtocolError(code: .unavailable,
            message: "Motor de design desatualizado: peça ao usuário para atualizá-lo em Preferências › Desenho e sandbox do Collie."))
    }

    @Test func failedVerifySaysAltered() async throws {
        let fx = Fixture(), box = EngineBox(engineDir(fakeServer, in: fx.dir))
        box.signed = false
        do { _ = try await fx.server(box).ensureRunning(); Issue.record("started") } catch {
            #expect(error == ProtocolError(code: .unavailable, message: "Motor alterado, baixe de novo"))
        }
        #expect(fx.starts.isEmpty)
    }

    @Test func holdBlocksStartWithoutFallingBack() async throws {
        let fx = Fixture(), box = EngineBox(engineDir(fakeServer, in: fx.dir))
        let s = fx.server(box)
        try await s.holdWhenFree(reason: .swap, within: .seconds(1))
        box.engine = FigcraftEngine(dir: engineDir(fakeServer, in: fx.dir), version: nil, source: .bundle)
        do { _ = try await s.ensureRunning(); Issue.record("started while held") } catch {
            #expect(error == ProtocolError(code: .unavailable, message: "motor de design sendo trocado, tente de novo"))
        }
        #expect(fx.starts.isEmpty)
        await s.release(.swap)
        _ = try await s.ensureRunning()
        #expect(await s.runningEngine?.source == .bundle)
        await s.stop()
    }

    @Test func swapUnderHoldStartsNewEngine() async throws {
        let fx = Fixture(), a = engineDir(fakeServer, in: fx.dir), b = engineDir(fakeServer, in: fx.dir)
        let box = EngineBox(a), s = fx.server(box)
        _ = try await s.ensureRunning()
        #expect(await s.runningEngine?.dir == a)
        try await s.holdWhenFree(reason: .swap, within: .seconds(1))
        await s.stop()
        box.engine = FigcraftEngine(dir: b, version: nil, source: .appSupport)
        await s.release(.swap)
        _ = try await s.ensureRunning()
        #expect(await s.runningEngine?.dir == b)
        #expect(fx.starts.count == 2)
        await s.stop()
    }

    @Test func backupAndSwapHoldsAreIndependent() async throws {
        let fx = Fixture(), s = fx.server(EngineBox(engineDir(fakeServer, in: fx.dir)))
        await s.hold(.backup)
        // the swap waits for the backup, then gives up as busy
        do { try await s.holdWhenFree(reason: .swap, within: .milliseconds(200)); Issue.record("held during a backup") } catch {
            #expect(error == ProtocolError(code: .conflict, message: "backup em andamento"))
        }
        do { _ = try await s.ensureRunning(); Issue.record("started during a backup") } catch {
            #expect(error == ProtocolError(code: .unavailable, message: "design engine: backup in progress, retry"))
        }
        await s.release(.backup)
        try await s.holdWhenFree(reason: .swap, within: .seconds(1))
        await s.hold(.backup)
        await s.release(.backup)
        #expect(await s.isHeld)   // the swap's hold is still there
        await s.release(.swap)
        #expect(await !s.isHeld)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: realServer.path)))
    func realServerComesUp() async throws {
        let fx = Fixture(), s = fx.server(binary: realServer)
        let (url, key) = try await s.ensureRunning()
        #expect(url == "ws://127.0.0.1:\(fx.port)/?key=\(key)" && key.count >= 16, "\(url)")
        #expect(await healthy(fx.port))
        await s.stop()
        #expect(!(await healthy(fx.port)))   // stop waits for the group to be gone
    }
}
