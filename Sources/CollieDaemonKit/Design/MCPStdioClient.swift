import Foundation
import os
import CollieCore
import CollieProtocol

/// One `tools/call` answer: its text and image (base64-decoded) content, in order.
struct MCPResult: Sendable {
    var texts: [String]
    var images: [Data]
    var isError: Bool
}

/// An MCP client over a child's stdio (`figcraft-cli mcp`): one JSON-RPC object per line each way.
/// `init` runs the `initialize` handshake (`protocolVersion 2025-06-18`) and sends `notifications/initialized`.
/// One request is in flight at a time (callers queue); a reply is matched by `id`, so lines that are not JSON, notifications
/// and replies to an earlier timed-out request are skipped. A reply line over 16 MiB fails the request in flight and is
/// skipped. A tool answer with `isError` becomes `ProtocolError(.internal, its text)`; once the child is gone every call
/// fails `.unavailable` "design engine stopped". The child runs as a `LongProcess` (own group, pidfile, stderr dropped).
final class MCPStdioClient: Sendable {
    static let replyCap = 16 << 20
    private static let stopped = ProtocolError(code: .unavailable, message: "design engine stopped")

    private typealias Reply = Result<JSONValue, ProtocolError>
    private struct State {
        var buffer = Data()
        var skipping = false   // inside an oversized line: dropped up to its newline
        var nextId = 0
        var pending: (id: Int, done: CheckedContinuation<Reply, Never>)?
        var dead = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let gate = Gate()
    private let proc: LongProcess

    var isAlive: Bool { !state.withLock { $0.dead } }

    init(executable: URL, args: [String], env: [String: String], runDir: URL, name: String) async throws(ProtocolError) {
        let state = state
        proc = try LongProcess(executable: executable, args: args, env: env, runDir: runDir, stdin: true,
                               onData: { Self.received($0, state) },
                               onExit: { _ in
                                   state.withLock { $0.dead = true }
                                   Self.finish(state, nil, .failure(Self.stopped))
                               })
        do throws(ProtocolError) {
            _ = try await rpc("initialize", .object([
                "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string(name), "version": .string("1")])]), timeout: .seconds(30))
            let note = try Self.line(id: nil, "notifications/initialized", nil), proc = proc
            guard try await UnixSocketClient.offPool({ proc.write(note) }) else { throw Self.stopped }
        } catch {
            close()
            throw error
        }
    }

    deinit { proc.terminate() }

    /// `tools/call` of `tool`; `timeout` runs from when the request is sent (not while queued behind another).
    func call(_ tool: String, _ args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> MCPResult {
        let out = try await result(tool, args, timeout: timeout)
        if out.isError {
            let text = out.texts.joined(separator: "\n")
            throw ProtocolError(code: .internal, message: text.isEmpty ? "design engine: \(tool) failed" : text)
        }
        return out
    }

    /// `call`, with an `isError` answer returned (only transport failures throw).
    func result(_ tool: String, _ args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> MCPResult {
        let r = try await rpc("tools/call", .object(["name": .string(tool), "arguments": .object(args)]), timeout: timeout)
        guard case .object(let o) = r else { throw ProtocolError(code: .internal, message: "design engine: malformed \(tool) reply") }
        var out = MCPResult(texts: [], images: [], isError: o["isError"] == .bool(true))
        if case .array(let content)? = o["content"] {
            for case .object(let c) in content {
                switch (c["type"], c["text"], c["data"]) {
                case (.string("text")?, .string(let t)?, _): out.texts.append(t)
                case (.string("image")?, _, .string(let b)?): if let d = Data(base64Encoded: b) { out.images.append(d) }
                default: break
                }
            }
        }
        return out
    }

    /// A figcraft command through the `run_command` tool; its text answer decoded as JSON (a string if it is not JSON).
    func command(_ id: String, _ params: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue {
        let text = try await call("run_command", ["command": .string(id), "params": .object(params)], timeout: timeout)
            .texts.joined(separator: "\n")
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
    }

    /// Stops the child (TERM, then KILL); the call in flight and every later one fail `.unavailable`. Never blocks.
    func close() {
        state.withLock { $0.dead = true }
        Self.finish(state, nil, .failure(Self.stopped))
        proc.terminate()
    }

    private func rpc(_ method: String, _ params: JSONValue, timeout: Duration) async throws(ProtocolError) -> JSONValue {
        await gate.enter()
        defer { gate.leave() }
        let state = state, proc = proc
        let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let reply: Reply = await withCheckedContinuation { c in
            let id: Int? = state.withLock { s in
                guard !s.dead else { return nil }
                s.nextId += 1; s.pending = (s.nextId, c)
                return s.nextId
            }
            guard let id else { c.resume(returning: .failure(Self.stopped)); return }
            let line: Data
            do throws(ProtocolError) { line = try Self.line(id: id, method, params) } catch { Self.finish(state, id, .failure(error)); return }
            // the pipe may be full while the child is busy: write on a thread of its own, never on the pool
            Thread { if !proc.write(line) { Self.finish(state, id, .failure(Self.stopped)) } }.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + secs) {
                Self.finish(state, id, .failure(ProtocolError(code: .timeout, message: "design engine: \(method) timed out")))
            }
        }
        return try reply.get()
    }

    private struct Request: Encodable {
        let jsonrpc = "2.0"
        var id: Int?
        var method: String
        var params: JSONValue?
    }

    private static func line(id: Int?, _ method: String, _ params: JSONValue?) throws(ProtocolError) -> Data {
        guard var d = try? JSONEncoder().encode(Request(id: id, method: method, params: params)) else {
            throw ProtocolError(code: .internal, message: "design engine: cannot encode \(method)")
        }
        d.append(10)
        return d
    }

    /// Resumes the request in flight (only if it is `id`, when given) with `r`; a later answer to it is then ignored.
    private static func finish(_ state: OSAllocatedUnfairLock<State>, _ id: Int?, _ r: Reply) {
        let c: CheckedContinuation<Reply, Never>? = state.withLock { s in
            guard let p = s.pending, id == nil || p.id == id else { return nil }
            s.pending = nil
            return p.done
        }
        c?.resume(returning: r)
    }

    /// Reader thread: splits stdout into lines (capped at `replyCap`) and answers the request in flight.
    private static func received(_ chunk: Data, _ state: OSAllocatedUnfairLock<State>) {
        let (lines, oversized) = state.withLock { s in
            var lines: [Data] = [], oversized = false
            var rest = chunk[...]
            while !rest.isEmpty {
                let nl = rest.firstIndex(of: 10)
                let piece = rest[rest.startIndex..<(nl ?? rest.endIndex)]
                if !s.skipping {
                    if s.buffer.count + piece.count > replyCap {
                        s.buffer = Data(); s.skipping = true; oversized = true
                    } else {
                        s.buffer.append(piece)
                    }
                }
                guard let nl else { break }
                if s.skipping { s.skipping = false } else { lines.append(s.buffer); s.buffer = Data() }
                rest = rest[(nl + 1)...]
            }
            return (lines, oversized)
        }
        if oversized {
            finish(state, nil, .failure(ProtocolError(code: .internal, message: "design engine reply too large (over 16 MiB)")))
        }
        for l in lines {
            guard let m = try? JSONDecoder().decode(Message.self, from: l), m.method == nil,
                  case .number(let n)? = m.id, let id = Int(exactly: n) else { continue }
            finish(state, id, m.error.map {
                       .failure(ProtocolError(code: .internal, message: "design engine: \($0.message ?? "error \($0.code ?? 0)")"))
                   }
                   ?? .success(m.result ?? .null))
        }
    }

    private struct Message: Decodable {
        struct Failure: Decodable { var code: Int?; var message: String? }
        var id: JSONValue?
        var method: String?   // a notification or a request from the server: not an answer
        var result: JSONValue?
        var error: Failure?
    }

    /// FIFO async mutex: one request on the wire at a time.
    private final class Gate: Sendable {
        private let s = OSAllocatedUnfairLock(initialState: (busy: false, waiters: [CheckedContinuation<Void, Never>]()))
        func enter() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let go = s.withLock { st in
                    if !st.busy { st.busy = true; return true }
                    st.waiters.append(c); return false
                }
                if go { c.resume() }
            }
        }
        func leave() {
            let next: CheckedContinuation<Void, Never>? = s.withLock { st in
                if st.waiters.isEmpty { st.busy = false; return nil }
                return st.waiters.removeFirst()
            }
            next?.resume()
        }
    }
}
