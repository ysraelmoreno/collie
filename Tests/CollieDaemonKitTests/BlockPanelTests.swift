import Testing
import Foundation
import Network
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A loopback app service: answers every request with what it got ({method, target, body}) as JSON.
private final class EchoService: @unchecked Sendable {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    init() async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { c in Self.serve(c) }
        port = try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, any Error>) in
            let once = NSLock(); nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { [listener] st in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                if case .ready = st { done = true; k.resume(returning: listener.port!.rawValue) }
                if case .failed(let e) = st { done = true; k.resume(throwing: e) }
            }
            listener.start(queue: .global())
        }
    }
    func stop() { listener.cancel() }
    var base: String { "http://127.0.0.1:\(port)" }

    private static func serve(_ c: NWConnection) {
        c.start(queue: .global())
        read(c, Data())
    }
    /// Reads until the headers and `Content-Length` bytes of body are in, then answers.
    private static func read(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
            let all = got + (data ?? Data())
            guard let end = all.range(of: Data("\r\n\r\n".utf8)) else { return done ? c.cancel() : read(c, all) }
            let head = String(decoding: all[..<end.lowerBound], as: UTF8.self)
            let len = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = all[end.upperBound...]
            guard body.count >= len || done else { return read(c, all) }
            let line = head.split(separator: " ")
            let reply: JSONValue = .object(["method": .string(String(line[0])), "target": .string(String(line[1])),
                                            "body": .string(String(decoding: body, as: UTF8.self))])
            let json = try! JSONEncoder().encode(reply)
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(resp.utf8) + json, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}


private func manifest(base: String) -> Data {
    let m: [String: Any] = [
        "apiVersion": 2, "id": "kube", "name": "Kube", "version": "0.1.0", "placements": ["canvas"], "ui": base + "/", "service": ["base": base],
        "commands": [
            ["name": "pods", "summary": "List pods", "runs": "http", "http": ["method": "GET", "path": "/api/pods"],
             "params": [["name": "namespace", "type": "string", "positional": true]]],
            ["name": "restart", "summary": "Restart", "runs": "http", "http": ["method": "POST", "path": "/api/restart"], "confirm": true, "params": []],
            ["name": "scale", "summary": "Scale", "runs": "http", "http": ["method": "POST", "path": "/api/scale"], "params": []],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: m)
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 30)
}

/// Terminal chat, slice 4: a collie-ui block opened as a panel, linked to an approved app's GET command or a snapshot.
@Suite(.serialized) struct BlockPanelTests {
    @Test func attachLinksOnlyAnApprovedPlainGetCommand() async throws {
        try await PluginRegistry.exclusively {
            let svc = try await EchoService()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blocks-\(UUID().uuidString)").resolvingSymlinksInPath()
            let app = dir.appendingPathComponent(".collie/apps/kube")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir); svc.stop() }
            try manifest(base: svc.base).write(to: app.appendingPathComponent("collie-plugin.json"))

            try await withDaemon { d, p in
                #expect(try await admin(d, p, "paddock.create", ["name": .string("k"), "folder": .string(dir.path)]).ok)
                let s = try await admin(d, p, "admin.spawn", ["name": .string("A"), "preset": .string("shell"), "paddock": .string("k")])
                guard case .object(let so)? = s.result, case .string(let tid)? = so["id"] else { Issue.record("\(s)"); return }
                func block(_ source: String?) -> String {
                    #"{"kind":"status","items":[["a","b"]]"# + (source.map { #","source":"# + $0 } ?? "") + "}"
                }
                func attach(_ json: String) async throws -> [String: JSONValue] {
                    let r = try await admin(d, p, "admin.block.attach", ["terminal": .string(tid), "json": .string(json)])
                    guard case .object(let o)? = r.result else { Issue.record("\(r)"); return [:] }
                    return o
                }
                let src = #"{"app":"kube","command":"pods","params":{"namespace":"x"},"refresh":10}"#

                // not approved yet: a snapshot, and why
                var o = try await attach(block(src))
                #expect(o["linked"] == .bool(false) && o["panel"] == .string("bloco-1"))
                guard case .string(let why)? = o["why"] else { Issue.record("\(o)"); return }
                #expect(why.contains("não está aprovado"), "\(why)")
                // no source at all: a snapshot with no reason
                o = try await attach(block(nil))
                #expect(o["linked"] == .bool(false) && o["why"] == nil)
                // a block that is not a block is refused, nothing opens
                #expect(try await admin(d, p, "admin.block.attach", ["terminal": .string(tid), "json": .string(#"{"kind":"nope"}"#)]).ok == false)

                #expect(try await admin(d, p, "app.approve", ["id": .string("kube"), "paddock": .string("k")]).ok)
                o = try await attach(block(src))
                #expect(o["linked"] == .bool(true), "\(o)")
                guard case .string(let pid)? = o["id"] else { return }
                let ref = try await admin(d, p, "admin.block.refresh", ["panel": .string(pid)])
                guard case .object(let ro)? = ref.result, case .object(let data)? = ro["data"] else { Issue.record("\(ref)"); return }
                #expect(data["method"] == .string("GET") && data["target"] == .string("/api/pods?namespace=x"), "\(ref)")

                // a confirm command or a POST never refreshes by itself: snapshot, with the reason
                for cmd in ["restart", "scale", "missing"] {
                    o = try await attach(block(#"{"app":"kube","command":"\#(cmd)"}"#))
                    #expect(o["linked"] == .bool(false) && o["why"] != nil, "\(cmd) \(o)")
                }
                // a snapshot panel has nothing to refresh
                guard case .string(let snap)? = (try await attach(block(nil)))["id"] else { return }
                #expect(try await admin(d, p, "admin.block.refresh", ["panel": .string(snap)]).ok == false)
            }
            PluginRegistry.setExternal([])
        }
    }
}
