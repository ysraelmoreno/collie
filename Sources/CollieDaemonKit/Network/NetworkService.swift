import Foundation
import CollieNetwork
import CollieProtocol

/// The proxy a capture session runs through: `MitmProcess` in the daemon, a fake in tests.
protocol NetworkProxy: Sendable {
    var port: Int { get }
    var caCert: URL { get }
    var lines: AsyncStream<String> { get }
    var exited: Int32? { get }
    /// A new proxy on the same port (this one stopped first).
    func restart() async throws(ProtocolError) -> any NetworkProxy
    func stop()
}
extension MitmProcess: NetworkProxy {
    func restart() async throws(ProtocolError) -> any NetworkProxy { try await restarted() }
}

/// Device side of a session: `DeviceNetworkSetup` in the daemon, a fake in tests.
protocol NetworkDevice: Sendable {
    func attach(serial: String, port: Int, caCert: URL) async throws(ProtocolError) -> DeviceNetworkSetup.AttachResult
    func detach(serial: String, port: Int?) async throws(ProtocolError) -> [String]
    func reconcile(serial: String, activePort: Int?, caCert: URL?) async throws(ProtocolError) -> DeviceNetworkSetup.Reconcile
}
extension DeviceNetworkSetup: NetworkDevice {}

/// Runs the `network.*` commands: HTTP(S) capture of an Android emulator through mitmdump.
/// **One mitmdump per serial**: with `adb reverse` every device reaches the proxy as 127.0.0.1, so a shared one could not
/// tell whose flow is whose (the addon only sees the client address). Each session owns its proxy, its `FlowStore` and
/// the reader turning the addon's lines into flows; every flow change goes out as `network.flow` (a `FlowSummary` plus
/// `serial`, never a body) to the network panels.
/// While a session lives it is reconciled every `pollInterval` (reverse lost on reconnect, CA gone after a reboot,
/// mitmdump died); at daemon start every online emulator is reconciled with no session (a crashed daemon's leftovers
/// are undone so the device gets its network back). `stop()` detaches every device: a stopped daemon must not leave a
/// device pointing at a proxy that is gone.
actor NetworkService {
    struct Session {
        var proxy: any NetworkProxy
        var store: FlowStore
        var reader: Task<Void, Never>
        var attach: DeviceNetworkSetup.AttachResult
    }

    private var sessions: [String: Session] = [:]
    /// serial → attach in progress: concurrent callers share it.
    private var attaching: [String: Task<Session, Error>] = [:]
    private var poller: Task<Void, Never>?
    private let startProxy: @Sendable (String) async throws(ProtocolError) -> any NetworkProxy
    private let device: @Sendable () async throws(ProtocolError) -> any NetworkDevice
    private let onlineEmulators: @Sendable () async -> [String]
    private let emit: @Sendable (String, String, JSONValue) async -> Void
    private let pollInterval: Duration
    private let capacity: Int

    /// `emit(serial, name, payload)` reaches that serial's network panels. `startProxy(serial)` returns a proxy that
    /// already listens with its CA on disk.
    init(capacity: Int = 2000, pollInterval: Duration = .seconds(5),
         startProxy: @escaping @Sendable (String) async throws(ProtocolError) -> any NetworkProxy,
         device: @escaping @Sendable () async throws(ProtocolError) -> any NetworkDevice,
         onlineEmulators: @escaping @Sendable () async -> [String],
         emit: @escaping @Sendable (String, String, JSONValue) async -> Void) {
        self.capacity = capacity; self.pollInterval = pollInterval
        self.startProxy = startProxy; self.device = device; self.onlineEmulators = onlineEmulators; self.emit = emit
    }

    /// The daemon's: mitmdump from `mitmdump()` (looked up per use: it may be installed while the daemon runs), its CA in
    /// `<root>/network/mitm`, adb through `devices`.
    init(root: URL, runDir: URL, devices: DeviceService, mitmdump: @escaping @Sendable () -> URL?,
         emit: @escaping @Sendable (String, String, JSONValue) async -> Void) {
        let confdir = root.appendingPathComponent("network/mitm")
        self.init(
            startProxy: { _ throws(ProtocolError) in
                guard let u = mitmdump() else { throw MitmTool.missing }
                return try await MitmProcess.start(tool: MitmTool(url: u), addonSource: AddonScript.source, confdir: confdir, runDir: runDir)
            },
            device: { () throws(ProtocolError) in DeviceNetworkSetup(adb: try await devices.tool()) },
            onlineEmulators: { ((try? await devices.devices()) ?? []).filter { $0.state == "device" && $0.serial.hasPrefix("emulator-") }.map(\.serial) },
            emit: emit)
    }

    // MARK: commands

    /// Starts capturing `serial` (idempotent: an attached serial is re-checked, its device repaired if needed).
    func attach(_ serial: String) async throws(ProtocolError) -> JSONValue {
        try DeviceNetworkSetup.guardEmulator(serial)
        if let s = sessions[serial] {
            _ = try await device().reconcile(serial: serial, activePort: s.proxy.port, caCert: s.proxy.caCert)
            return status(serial)
        }
        let t: Task<Session, Error>
        if let cur = attaching[serial] { t = cur } else {
            t = Task { defer { self.attaching[serial] = nil }; return try await self.startSession(serial) }
            attaching[serial] = t
        }
        do { sessions[serial] = try await t.value } catch let e as ProtocolError { throw e } catch {
            throw ProtocolError(code: .internal, message: "\(error)")
        }
        startPolling()
        return status(serial)
    }

    private func startSession(_ serial: String) async throws(ProtocolError) -> Session {
        let proxy = try await startProxy(serial)
        do {
            let r = try await device().attach(serial: serial, port: proxy.port, caCert: proxy.caCert)
            return Session(proxy: proxy, store: FlowStore(capacity: capacity, serial: serial), reader: read(serial, proxy), attach: r)
        } catch {
            proxy.stop()
            throw error
        }
    }

    /// Stops capturing `serial` and restores its device. Flows are dropped with the session.
    func detach(_ serial: String) async throws(ProtocolError) -> JSONValue {
        try DeviceNetworkSetup.guardEmulator(serial)
        let s = sessions.removeValue(forKey: serial)
        s?.reader.cancel(); s?.proxy.stop()
        if sessions.isEmpty { poller?.cancel(); poller = nil }
        let log = try await device().detach(serial: serial, port: s?.proxy.port)
        return .object(["serial": .string(serial), "attached": .bool(false), "steps": .array(log.map { .string($0) })])
    }

    func status(_ serial: String) -> JSONValue {
        guard let s = sessions[serial] else { return .object(["serial": .string(serial), "attached": .bool(false)]) }
        return .object([
            "serial": .string(serial), "attached": .bool(true), "port": .number(Double(s.proxy.port)),
            "flows": .number(Double(s.store.summaries.count)), "sdk": .number(Double(s.attach.sdk)), "ca": .string(s.attach.hash),
            "proxyRunning": .bool(s.proxy.exited == nil),
        ])
    }

    /// The newest `limit` summaries (oldest first), those whose host contains `host` when given.
    func list(_ serial: String, limit: Int = 100, host: String? = nil) throws(ProtocolError) -> JSONValue {
        var all = try session(serial).store.summaries
        if let host, !host.isEmpty { all = all.filter { $0.host.localizedCaseInsensitiveContains(host) } }
        return Self.json(Array(all.suffix(limit)))
    }

    /// The whole flow, dates in epoch seconds. Bodies as captured (`data`: base64, still content-encoded) plus, when the
    /// encoding can be undone and the result is UTF-8, `reqBodyText`/`resBodyText` (JSON pretty-printed).
    func get(_ serial: String, id: String) throws(ProtocolError) -> JSONValue {
        let f = try flow(serial, id)
        guard case .object(var o) = Self.json(f) else { return .null }
        for (key, body) in [("reqBodyText", f.reqBody), ("resBodyText", f.resBody)] {
            if let body, let data = BodyDecoder.decode(body), let text = BodyDecoder.prettyJSON(data) ?? String(data: data, encoding: .utf8) {
                o[key] = .string(text)
            }
        }
        return .object(o)
    }

    func curl(_ serial: String, id: String) throws(ProtocolError) -> JSONValue {
        .object(["curl": .string(Curl.render(try flow(serial, id)))])
    }

    func clear(_ serial: String) throws(ProtocolError) -> JSONValue {
        try session(serial)
        sessions[serial]?.store.clear()
        return .object(["serial": .string(serial), "flows": .number(0)])
    }

    /// Serials being captured.
    var attached: [String] { Array(sessions.keys).sorted() }

    // MARK: lifecycle

    /// Daemon start: undo what a previous daemon left on the online emulators (no session survives a restart).
    func reconcileAtStart() async {
        guard let d = try? await device() else { return }   // no adb: nothing to undo
        for serial in await onlineEmulators() where sessions[serial] == nil {
            _ = try? await d.reconcile(serial: serial, activePort: nil, caCert: nil)
        }
    }

    /// One pass over the live sessions: a dead mitmdump is restarted on its port; the device is reconciled.
    func reconcileSessions() async {
        for serial in Array(sessions.keys) {
            guard var s = sessions[serial] else { continue }
            if s.proxy.exited != nil, let fresh = try? await s.proxy.restart() {
                guard sessions[serial] != nil else { fresh.stop(); continue }   // detached meanwhile
                s.reader.cancel()
                s.proxy = fresh; s.reader = read(serial, fresh)
                sessions[serial] = s
            }
            _ = try? await device().reconcile(serial: serial, activePort: s.proxy.port, caCert: s.proxy.caCert)
        }
    }

    /// Daemon stop: every device detached (bounded by adb's own timeouts), every proxy stopped.
    func stop() async {
        poller?.cancel(); poller = nil
        let all = sessions; sessions = [:]
        for (serial, s) in all {
            s.reader.cancel(); s.proxy.stop()
            _ = try? await device().detach(serial: serial, port: s.proxy.port)
        }
    }

    // MARK: internals

    private func startPolling() {
        guard poller == nil else { return }
        let interval = pollInterval
        poller = Task { while !Task.isCancelled { try? await Task.sleep(for: interval); await self.reconcileSessions() } }
    }

    /// The addon's lines → flows → `network.flow`. Ends with the proxy's stdout (a restart starts a new reader).
    private func read(_ serial: String, _ proxy: any NetworkProxy) -> Task<Void, Never> {
        Task {
            for await line in proxy.lines {
                guard !Task.isCancelled else { return }
                guard let event = FlowEvent.decode(line: line) else { continue }
                await self.ingest(serial, event)
            }
        }
    }

    private func ingest(_ serial: String, _ event: FlowEvent) async {
        guard let summary = sessions[serial]?.store.apply(event), case .object(var o) = Self.json(summary) else { return }
        o["serial"] = .string(serial)
        await emit(serial, "network.flow", .object(o))
    }

    @discardableResult
    private func session(_ serial: String) throws(ProtocolError) -> Session {
        guard let s = sessions[serial] else {
            throw ProtocolError(code: .notFound, message: "\(serial) is not being captured; run network.attach first")
        }
        return s
    }

    private func flow(_ serial: String, _ id: String) throws(ProtocolError) -> Flow {
        guard let f = try session(serial).store.flow(id) else { throw ProtocolError(code: .notFound, message: "No flow '\(id)' on \(serial)") }
        return f
    }

    static func json(_ v: some Encodable) -> JSONValue {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let d = try? e.encode(v), let j = try? JSONDecoder().decode(JSONValue.self, from: d) else { return .null }
        return j
    }
}
