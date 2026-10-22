import Foundation
import Observation
import OrqCore
import OrqProtocol

public enum ConnectionState: Sendable, Equatable { case connected, disconnected(reason: String) }

/// The app's view of the daemon: a workspace mirror (snapshot + events) that reconnects on its own,
/// admin commands, and per-terminal streams. Socket I/O runs off the main thread; state is published here.
@MainActor @Observable public final class DaemonClient {
    public private(set) var state: ConnectionState = .disconnected(reason: "not started")
    public private(set) var terminals: [TerminalRecord] = []
    public private(set) var connections: [Connection] = []
    public private(set) var badges: [UUID: StatusBadge] = [:]
    public private(set) var floors: [Floor] = []
    public private(set) var panels: [Panel] = []
    /// `BuildID` of the connected daemon (nil: not connected yet, or a daemon that predates it).
    public private(set) var daemonBuild: String?
    /// The `ui.host` role: `.replaced` when another Orq window took it (see `resumeHost()`).
    public private(set) var hostStatus: HostConnection.Status = .idle
    /// The default workspace's id (for plugin storage), read once connected.
    public private(set) var workspaceId: UUID?
    /// The floor the canvas shows (nil = ground). View state; the app persists it.
    public var currentFloor: UUID?

    /// Called (main actor) when a terminal starts waiting for the user: id and reason.
    @ObservationIgnored public var onAttention: ((UUID, String) -> Void)?
    /// Called (main actor) when a Maestro runs `orq notify`: terminal id and message.
    @ObservationIgnored public var onNotify: ((UUID, String) -> Void)?
    /// Called (main actor) on `partitura.applied`: applying terminal (nil = the app), anchor Maestro, frames by node id,
    /// the floor it created.
    @ObservationIgnored public var onPartituraApplied: ((UUID?, UUID?, [String: PartituraFrame], UUID?) -> Void)?

    /// Runs a plugin command for a panel (set by the app; the host forwards the daemon's calls here).
    public typealias PanelHandler = @MainActor @Sendable (_ panel: UUID, _ command: String, _ args: [String: JSONValue], _ timeoutSeconds: Double) async throws(ProtocolError) -> JSONValue
    @ObservationIgnored public var panelHandler: PanelHandler?

    /// Called (main actor) for every plugin event on `ui.events`: panel, name, payload (the app routes it to the panel's view).
    @ObservationIgnored public var pluginEventHandler: (@MainActor (UUID, String, JSONValue) -> Void)?

    private let paths: Paths
    @ObservationIgnored private var host: HostConnection?
    @ObservationIgnored private var hostWatch: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: StreamClient?
    /// Bumped by start() and stop(): a session from an older generation never touches published state.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var openEventStreams = 0   // diagnostics/tests

    public init(paths: Paths = Paths()) { self.paths = paths }

    /// Connects, mirrors `ui.events`, and reconnects with backoff 0.25 s → 2 s (each attempt re-reads admin.token).
    public func start() {
        guard loop == nil else { return }
        resumeHost()
        generation += 1
        let gen = generation
        loop = Task { [weak self] in
            var delay = 0.25
            while let self, self.live(gen) {
                let reason = await self.session(gen) { delay = 0.25 }
                guard self.live(gen) else { return }
                self.state = .disconnected(reason: reason)
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 2)
            }
        }
    }

    /// Stops reconnecting and closes the events stream. Owns the final `.disconnected("stopped")`.
    public func stop() {
        generation += 1
        loop?.cancel(); loop = nil
        events?.close(); events = nil
        hostWatch?.cancel(); hostWatch = nil
        host?.stop(); host = nil; hostStatus = .idle
        state = .disconnected(reason: "stopped")
    }

    /// Starts a fresh HostConnection (also the way to take the host role back after `.replaced`).
    public func resumeHost() {
        host?.stop()
        hostWatch?.cancel()
        let paths = paths
        let h = HostConnection(paths: paths, token: { try Self.readToken(paths) }) { [weak self] panel, command, args, timeout throws(ProtocolError) in
            guard let run = await self?.panelHandler else { throw ProtocolError(code: .unavailable, message: "Plug-in indisponível") }
            return try await run(panel, command, args, timeout)
        }
        host = h
        h.start()
        hostStatus = h.status
        // ponytail: polls (HostConnection has no callback); 0.5 s is plenty for a toolbar notice
        hostWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.host === h else { return }
                if self.hostStatus != h.status { self.hostStatus = h.status }
            }
        }
    }

    /// A plugin event for `panel` (dropped while the host is disconnected).
    public func emit(panel: UUID, name: String, payload: JSONValue) { host?.emit(panel: panel, name: name, payload: payload) }

    private func live(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    /// One connection: until the events stream ends. Returns why it ended. Opening and the snapshot do not observe
    /// cancellation, so every await is followed by a generation check before anything is published.
    private func session(_ gen: Int, onConnected: () -> Void) async -> String {
        do {
            let token = try adminToken()
            // Subscribe first, then snapshot: events emitted during the fetch wait in the stream and are applied on
            // top of the snapshot, in order. Every event is idempotent by id (upsert/remove), so the overlap is harmless
            // and nothing between the snapshot and the subscription is lost.
            let ev = try await StreamClient.open(Request(id: "events", token: token, command: "ui.events"), path: paths.socket)
            openEventStreams += 1
            defer { ev.close(); openEventStreams -= 1; if events === ev { events = nil } }
            guard live(gen) else { return "stopped" }
            events = ev
            let result = try await call("ui.snapshot", [:], token: token)
            guard live(gen) else { return "stopped" }
            guard let result else { return "empty snapshot" }
            let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(result))
            terminals = snap.terminals
            connections = snap.connections
            floors = snap.floors
            panels = snap.panels
            daemonBuild = snap.build
            workspaceId = (try? String(contentsOf: paths.root.appendingPathComponent("default-workspace"), encoding: .utf8))
                .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if let c = currentFloor, !floors.contains(where: { $0.id == c }) { currentFloor = nil }   // deleted while away
            badges = Dictionary(uniqueKeysWithValues: snap.badges.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
            state = .connected
            onConnected()
            for await f in Self.frames(of: ev) {
                guard live(gen) else { return "stopped" }
                if case .event(let e) = f { apply(e) }
            }
            return "events stream closed"
        } catch let e as ProtocolError {
            return e.message
        } catch {
            return "\(error)"
        }
    }

    /// The events stream read on its own thread (long-lived blocking read; see `UnixSocketClient.offPool`).
    /// Ends when the stream closes (EOF, error, or `close()`).
    private nonisolated static func frames(of ev: StreamClient) -> AsyncStream<StreamFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { cont in
            Thread {
                // A dropped event ends the stream: `session` returns, closes `ev`, and the reconnect re-snapshots.
                while let f = try? ev.nextBlocking(timeoutSeconds: forever) {
                    if case .dropped = cont.yield(f) { break }
                }
                cont.finish()
            }.start()
        }
    }

    func apply(_ e: WorkspaceEvent) {   // internal: tests feed events directly
        switch e {
        case .spawned(let r), .terminal(let r):
            if let i = terminals.firstIndex(where: { $0.id == r.id }) { terminals[i] = r } else { terminals.append(r) }
        case .exited(let id, _): badges[id] = .stopped
        case .removed(let id):
            terminals.removeAll { $0.id == id }
            connections.removeAll { $0.a == id || $0.b == id }
            badges[id] = nil
        case .connected(let c): if !connections.contains(where: { same($0, c) }) { connections.append(c) }
        case .disconnected(let c): connections.removeAll { same($0, c) }
        case .status(let id, let b): badges[id] = b
        case .attention(let id, let why): onAttention?(id, why)   // the badge itself arrives as .status
        case .floor(let f):
            if let i = floors.firstIndex(where: { $0.id == f.id }) { floors[i] = f } else { floors.append(f) }
        case .floorRemoved(let id): floors.removeAll { $0.id == id }
        case .notify(let id, let message): onNotify?(id, message)
        case .panel(let p):
            if let i = panels.firstIndex(where: { $0.id == p.id }) { panels[i] = p } else { panels.append(p) }
        case .panelRemoved(let id):
            panels.removeAll { $0.id == id }
            connections.removeAll { $0.a == id || $0.b == id }
        case .pluginEvent(let panel, let name, let payload): pluginEventHandler?(panel, name, payload)
        case .partituraApplied(let by, let anchor, let frames, let floor): onPartituraApplied?(by, anchor, frames, floor)
        }
    }
    private func same(_ x: Connection, _ y: Connection) -> Bool { Set([x.a, x.b]) == Set([y.a, y.b]) }

    // MARK: commands

    public func spawn(name: String, preset: Preset, command: String?, cwd: String, maestro: Bool, floor: String? = nil) async throws -> UUID {
        var args: [String: JSONValue] = ["name": .string(name), "preset": .string(preset.rawValue),
                                         "cwd": .string(cwd), "maestro": .bool(maestro)]
        if let command { args["command"] = .string(command) }
        if let floor { args["floor"] = .string(floor) }
        guard case .object(let o)? = try await admin("admin.spawn", args),
              case .string(let s)? = o["id"], let id = UUID(uuidString: s) else {
            throw ProtocolError(code: .internal, message: "malformed spawn reply")
        }
        return id
    }
    public func connect(_ a: String, _ b: String) async throws { _ = try await admin("admin.connect", ["a": .string(a), "b": .string(b)]) }
    public func disconnect(_ a: String, _ b: String) async throws { _ = try await admin("admin.disconnect", ["a": .string(a), "b": .string(b)]) }
    public func kill(_ name: String) async throws { _ = try await admin("admin.kill", ["target": .string(name)]) }
    public func restart(_ name: String) async throws { _ = try await admin("admin.restart", ["name": .string(name)]) }
    /// Edits a terminal; `restartNeeded`: launch settings changed under a running process.
    @discardableResult
    public func update(_ name: String, newName: String? = nil, maestro: Bool? = nil, preset: Preset? = nil,
                       command: String? = nil, cwd: String? = nil, restart: Bool = false) async throws -> (restartNeeded: Bool, restarted: Bool) {
        var args: [String: JSONValue] = ["name": .string(name), "restart": .bool(restart)]
        if let newName { args["newName"] = .string(newName) }
        if let maestro { args["maestro"] = .bool(maestro) }
        if let preset { args["preset"] = .string(preset.rawValue) }
        if let command { args["command"] = .string(command) }
        if let cwd { args["cwd"] = .string(cwd) }
        guard case .object(let o)? = try await admin("admin.update", args),
              case .bool(let n)? = o["restartNeeded"], case .bool(let d)? = o["restarted"] else {
            throw ProtocolError(code: .internal, message: "malformed update reply")
        }
        return (n, d)
    }

    public func createFloor(name: String, repo: String) async throws {
        _ = try await admin("floor.create", ["name": .string(name), "repo": .string(repo)], timeout: 300)
    }
    public func setFloorStatus(_ name: String, _ status: FloorStatus) async throws {
        _ = try await admin("floor.status", ["name": .string(name), "status": .string(status.rawValue)])
    }
    /// Can take minutes (git merge/rebase, push for `pr`).
    public func land(_ name: String, mode: LandMode, message: String? = nil) async throws -> LandResult {
        var args: [String: JSONValue] = ["name": .string(name), "mode": .string(mode.rawValue)]
        if let message { args["message"] = .string(message) }
        guard let r = try await admin("floor.land", args, timeout: 900) else { throw ProtocolError(code: .internal, message: "malformed land reply") }
        return try JSONDecoder().decode(LandResult.self, from: JSONEncoder().encode(r))
    }
    public func deleteFloor(_ name: String, force: Bool) async throws {
        var args: [String: JSONValue] = ["name": .string(name)]
        if force { args["force"] = .bool(true) }
        _ = try await admin("floor.delete", args, timeout: 300)
    }
    public func usage() async throws -> [UsageReport] {
        guard let r = try await admin("ui.usage", [:], timeout: 130) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode([UsageReport].self, from: JSONEncoder().encode(r))
    }

    /// Name of a terminal or panel (cords can end at either).
    public func nodeName(_ id: UUID) -> String? { terminals.first { $0.id == id }?.name ?? panels.first { $0.id == id }?.name }
    private var currentFloorName: String? { floors.first { $0.id == currentFloor }?.name }

    /// A canvas panel opens on the floor being shown; a shut-down iOS Simulator boots first (up to ~2 min).
    /// Returns the new panel's id.
    @discardableResult
    public func openPanel(plugin: String, name: String?, placement: PanelPlacement, url: String?, storage: StorageScope,
                          serial: String? = nil, file: String? = nil) async throws -> UUID {
        var args: [String: JSONValue] = ["plugin": .string(plugin), "placement": .string(placement.rawValue), "storage": .string(storage.rawValue)]
        if let name, !name.isEmpty { args["name"] = .string(name) }
        if let url, !url.isEmpty { args["url"] = .string(url) }
        if placement == .canvas, let f = currentFloorName { args["floor"] = .string(f) }
        if let serial, !serial.isEmpty { args["serial"] = .string(serial) }
        if let file, !file.isEmpty { args["file"] = .string(file) }
        // a design file's first open can start the design engine
        guard case .object(let o)? = try await admin("panel.open", args, timeout: serial != nil ? 190 : file != nil ? 60 : 10),
              case .string(let s)? = o["id"], let id = UUID(uuidString: s) else {
            throw ProtocolError(code: .internal, message: "malformed panel.open reply")
        }
        return id
    }
    /// A plug-in command's own timeout plus 5 s (the daemon times it out itself; its typed `.timeout` arrives first,
    /// as in the CLI); else 30 s.
    public nonisolated static func adminTimeout(_ command: String) -> Double {
        PluginRegistry.command(command)?.1.timeoutSeconds.map { $0 + 5 } ?? 30
    }
    /// A raw admin command for app-side plug-in views (`PanelHostContext.call`).
    /// `timeout` nil: `adminTimeout(command)`.
    public func adminCall(_ command: String, _ args: [String: JSONValue], timeout: Double? = nil) async throws(ProtocolError) -> JSONValue {
        do { return try await admin(command, args, timeout: timeout ?? Self.adminTimeout(command)) ?? .null }
        catch let e as ProtocolError { throw e }
        catch { throw ProtocolError(code: .internal, message: "\(error)") }
    }
    /// An admin `ui.*` stream for app-side plug-in views (`PanelHostContext.openStream`, e.g. `ui.device`).
    public nonisolated func openAdminStream(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> StreamClient {
        let token: String
        do { token = try Self.readToken(paths) } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .daemonUnavailable, message: "\(error)") }
        return try await StreamClient.open(Request(id: UUID().uuidString, token: token, command: command, args: args), path: paths.socket)
    }
    public func closePanel(_ name: String) async throws { _ = try await admin("panel.close", ["name": .string(name)]) }
    public func movePanel(_ name: String, to placement: PanelPlacement) async throws {
        var args: [String: JSONValue] = ["name": .string(name), "placement": .string(placement.rawValue)]
        if placement == .canvas, let f = currentFloorName { args["floor"] = .string(f) }
        _ = try await admin("panel.move", args)
    }

    public func attach(_ id: UUID) -> TerminalStream {
        let paths = paths
        return TerminalStream(terminal: id, socket: paths.socket) { try? Self.readToken(paths) }
    }

    /// An admin command. The token is re-read per attempt: a restarted daemon rotates it (and briefly refuses
    /// the old one), so `.unauthorized` / `.daemonUnavailable` retry with backoff for up to ~4 s.
    private func admin(_ command: String, _ args: [String: JSONValue], timeout: Double = 10) async throws -> JSONValue? {
        var delay = 0.25
        let deadline = ContinuousClock.now + .seconds(4)
        while true {
            do { return try await call(command, args, token: try adminToken(), timeout: timeout) }
            catch let e as ProtocolError where [.unauthorized, .daemonUnavailable].contains(e.code)
                    && ContinuousClock.now + .seconds(delay) < deadline {
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 2)
            }
        }
    }

    private func call(_ command: String, _ args: [String: JSONValue], token: String, timeout: Double = 10) async throws -> JSONValue? {
        let r = try await UnixSocketClient.send(Request(id: UUID().uuidString, token: token, command: command, args: args),
                                                to: paths.socket, timeoutSeconds: timeout)
        guard r.ok else { throw r.error ?? ProtocolError(code: .internal, message: "\(command) failed") }
        return r.result
    }

    private func adminToken() throws -> String { try Self.readToken(paths) }
    nonisolated static func readToken(_ paths: Paths) throws -> String {
        guard let t = try? String(contentsOf: paths.adminTokenFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            throw ProtocolError(code: .daemonUnavailable, message: "no admin token (is orqd running?)")
        }
        return t
    }
}


public struct LandResult: Codable, Sendable, Equatable {
    public var mode: LandMode
    public var commit: String?
    public var prURL: String?
}

/// Terminals shown on a floor (nil = ground).
public func visibleTerminals(_ terminals: [TerminalRecord], floor: UUID?) -> [TerminalRecord] {
    terminals.filter { $0.floorId == floor }
}

/// Canvas panels of this floor (nil = ground), plus every docked panel (docks show on every floor).
public func visiblePanels(_ panels: [Panel], floor: UUID?) -> [Panel] {
    panels.filter { $0.placement != .canvas || $0.floorId == floor }
}

/// What the edit form changed against `original`; unchanged fields are nil (not sent). Text is trimmed.
/// `command` only counts for the custom preset (the daemon needs it there and ignores it elsewhere).
public func editArgs(original: TerminalRecord, name: String, maestro: Bool, preset: Preset, command: String, cwd: String)
    -> (newName: String?, maestro: Bool?, preset: Preset?, command: String?, cwd: String?) {
    let n = name.trimmingCharacters(in: .whitespaces), c = command.trimmingCharacters(in: .whitespaces)
    let d = cwd.trimmingCharacters(in: .whitespaces)
    return (n != original.name ? n : nil, maestro != original.isMaestro ? maestro : nil,
            preset != original.preset ? preset : nil,
            preset == .custom && c != (original.command ?? "") ? c : nil,
            !d.isEmpty && d != original.cwd ? d : nil)
}
