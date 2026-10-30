import AppKit
import Foundation
import SwiftUI
import Testing
import CollieCore
import CollieNetwork
import CollieProtocol
@testable import ColliePlugins

private func summary(_ id: String, _ method: String = "GET", host: String = "api.example.com", path: String = "/v1/items",
                     status: Int? = 200, state: JSONValue = .object(["done": .object([:])]), serial: String = "emulator-5554") -> JSONValue {
    var o: [String: JSONValue] = ["id": .string(id), "method": .string(method), "host": .string(host), "path": .string(path),
                                  "state": state, "serial": .string(serial), "size": .number(2048), "durationMs": .number(120)]
    if let status { o["status"] = .number(Double(status)) }
    return .object(o)
}

private func flowJSON(_ id: String, resBody: Data = Data(#"{"ok":true}"#.utf8), encoding: String? = nil, text: String? = nil) -> JSONValue {
    var body: [String: JSONValue] = ["size": .number(Double(resBody.count)), "truncated": .bool(false), "data": .string(resBody.base64EncodedString())]
    if let encoding { body["contentEncoding"] = .string(encoding) }
    var o: [String: JSONValue] = [
        "id": .string(id), "serial": .string("emulator-5554"), "started": .number(1_790_000_000), "method": .string("GET"),
        "url": .string("https://api.example.com/v1/items?page=2"), "httpVersion": .string("HTTP/2.0"),
        "reqHeaders": .array([.object(["name": .string("accept"), "value": .string("application/json")])]),
        "status": .number(200), "reason": .string("OK"),
        "resHeaders": .array([.object(["name": .string("content-type"), "value": .string("application/json")])]),
        "resBody": .object(body),
        "timing": .object(["start": .number(1_790_000_000), "ttfb": .number(1_790_000_000.12), "end": .number(1_790_000_000.34)]),
        "state": .object(["done": .object([:])]),
    ]
    if let text { o["resBodyText"] = .string(text) }
    return .object(o)
}

private actor Fake {
    var calls: [(String, [String: JSONValue])] = []
    var attachResult: JSONValue = .object(["attached": .bool(true), "port": .number(8090), "restartSuggested": .array([.string("com.android.chrome")])])
    var failure: ProtocolError?
    func set(failure: ProtocolError?) { self.failure = failure }
    func handle(_ cmd: String, _ a: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        calls.append((cmd, a))
        if let failure { throw failure }
        switch cmd {
        case "device.list":
            return .array([
                .object(["serial": .string("emulator-5554"), "state": .string("device"), "platform": .string("android")]),
                .object(["serial": .string("R58M123"), "state": .string("device"), "platform": .string("android")]),
                .object(["serial": .string("avd:Pixel"), "state": .string("off"), "platform": .string("android")]),
                .object(["serial": .string("ABCD-1234"), "state": .string("Booted"), "platform": .string("ios")]),
            ])
        case "network.status": return .object(["attached": .bool(false)])
        case "network.attach": return attachResult
        case "network.list": return .array([summary("old")])
        case "network.get":
            if str(a["id"]) == "big" { return flowJSON("big", resBody: Data(repeating: 0xAB, count: 200 * 1024), encoding: "gzip") }
            return flowJSON(str(a["id"]), text: "{\n  \"ok\" : true\n}")
        case "network.curl": return .object(["curl": .string("curl 'https://api.example.com/v1/items?page=2'")])
        default: return .object([:])
        }
    }
    func commands() -> [String] { calls.map(\.0) }
    private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }
}

@MainActor private func model(_ fake: Fake) -> NetworkPanelModel {
    NetworkPanelModel(call: { c, a throws(ProtocolError) in try await fake.handle(c, a) })
}

@MainActor @Suite struct NetworkPanelTests {
    @Test func refreshListsOnlyOnlineEmulatorsAndPicksTheFirst() async {
        let m = model(Fake())
        await m.refresh()
        #expect(m.emulators == ["emulator-5554"])
        #expect(m.serial == "emulator-5554")
        #expect(!m.attached)
    }

    @Test func eventsAppendThenUpdateTheSameFlow() {
        let m = model(Fake()); m.serial = "emulator-5554"
        m.apply(event: "network.flow", payload: summary("a", status: nil, state: .object(["pending": .object([:])])))
        #expect(m.visible.count == 1 && NetworkPanelModel.tone(m.visible[0].summary) == .pending)
        m.apply(event: "network.flow", payload: summary("a", status: 404))
        #expect(m.visible.count == 1 && m.visible[0].summary.status == 404)
        m.apply(event: "other.event", payload: summary("b"))
        m.apply(event: "network.flow", payload: .object(["id": .string("c")]))   // no serial / not a summary
        #expect(m.rows.count == 1)
    }

    @Test func visibleFiltersBySerialAndText() {
        let m = model(Fake()); m.serial = "emulator-5554"
        m.apply(event: "network.flow", payload: summary("a", "POST", host: "auth.example.com", path: "/login", status: 201))
        m.apply(event: "network.flow", payload: summary("b", host: "cdn.example.com", path: "/img.png", status: 304))
        m.apply(event: "network.flow", payload: summary("c", serial: "emulator-5556"))
        #expect(m.visible.map(\.id) == ["a", "b"])
        m.filter = "post"; #expect(m.visible.map(\.id) == ["a"])
        m.filter = "IMG"; #expect(m.visible.map(\.id) == ["b"])
        m.filter = "304"; #expect(m.visible.map(\.id) == ["b"])
        m.filter = "  "; #expect(m.visible.count == 2)
        m.serial = "emulator-5556"; #expect(m.visible.map(\.id) == ["c"])
    }

    @Test func toneByStatusClassAndState() {
        func t(_ status: Int?, _ state: JSONValue = .object(["done": .object([:])])) -> FlowTone {
            NetworkPanelModel.tone(NetworkPanelModel.decode(FlowSummary.self, summary("x", status: status, state: state))!)
        }
        #expect(t(200) == .success && t(302) == .redirect && t(404) == .clientError && t(503) == .serverError)
        #expect(t(nil, .object(["failed": .object(["_0": .string("boom")])])) == .failed)
        #expect(t(nil, .object(["tunneled": .object([:])])) == .tunneled)
        #expect(t(nil, .object(["pending": .object([:])])) == .pending)
    }

    @Test func sizeAndDurationFormatting() {
        #expect(NetworkPanelModel.size(nil) == "—" && NetworkPanelModel.size(512) == "512 B")
        #expect(NetworkPanelModel.size(2048) == "2.0 KB" && NetworkPanelModel.size(3 * 1024 * 1024) == "3.0 MB")
        #expect(NetworkPanelModel.duration(nil) == "—" && NetworkPanelModel.duration(87) == "87 ms" && NetworkPanelModel.duration(1530) == "1.53 s")
    }

    @Test func attachKeepsPortAndRestartHintAndSeedsTheList() async {
        let fake = Fake(), m = model(fake)
        await m.refresh()
        await m.toggle()
        #expect(m.attached && m.port == 8090 && m.restartSuggested == ["com.android.chrome"])
        #expect(m.visible.map(\.id) == ["old"])
        await m.toggle()
        #expect(!m.attached && m.port == nil && m.restartSuggested.isEmpty && m.visible.isEmpty)
        #expect(await fake.commands().suffix(3) == ["network.attach", "network.list", "network.detach"])
    }

    @Test func attachErrorIsShownAsIs() async {
        let fake = Fake(), m = model(fake)
        await m.refresh()
        await fake.set(failure: ProtocolError(code: .unavailable, message: "mitmdump not found; brew install --cask mitmproxy"))
        await m.toggle()
        #expect(!m.attached && m.error?.contains("brew install --cask mitmproxy") == true)
    }

    @Test func selectingAFlowDecodesTheDetail() async throws {
        let m = model(Fake()); m.serial = "emulator-5554"
        await m.select(flow: "a")
        let d = try #require(m.detail)
        #expect(d.flow.url == "https://api.example.com/v1/items?page=2" && d.flow.reason == "OK" && d.flow.httpVersion == "HTTP/2.0")
        #expect(d.flow.timing.ttfb != nil && d.flow.reqHeaders.first?.name == "accept")
        #expect(d.resPreview.view == .text("{\n  \"ok\" : true\n}") && !d.resPreview.isPartial)
    }

    @Test func bodyFallsBackToUTF8ThenHex() throws {
        let plain = try #require(NetworkPanelModel.decode(Flow.self, flowJSON("a", resBody: Data("hi".utf8))))
        #expect(NetworkPanelModel.body(plain.resBody, text: nil).view == .text("hi"))
        let gz = try #require(NetworkPanelModel.decode(Flow.self, flowJSON("a", resBody: Data([0x1f, 0x8b, 0x08, 0x41]), encoding: "gzip")))
        #expect(NetworkPanelModel.body(gz.resBody, text: nil).view == .hex("00000000  1f 8b 08 41" + String(repeating: " ", count: 36) + "  ...A"))
        #expect(NetworkPanelModel.body(nil, text: nil).view == .empty)
    }

    @Test func longTextPreviewIsCutOnACharacterAndCopiesWhole() {
        let limit = NetworkPanelModel.textPreviewLimit, long = String(repeating: "a", count: limit - 1) + "é" + "bbb"
        let p = NetworkPanelModel.body(nil, text: long)
        #expect(p.isPartial && p.shown == limit - 1 && p.total == long.utf8.count)
        #expect(p.view == .text(String(repeating: "a", count: limit - 1)))
        #expect(NetworkPanelModel.fullBody(nil, text: long) == long)
    }

    @Test func binaryPreviewIsCappedAndCopiesBase64() throws {
        let raw = Data(repeating: 0xAB, count: NetworkPanelModel.hexPreviewLimit + 16)
        let f = try #require(NetworkPanelModel.decode(Flow.self, flowJSON("a", resBody: raw, encoding: "gzip")))
        let p = NetworkPanelModel.body(f.resBody, text: nil)
        #expect(p.isPartial && p.shown == NetworkPanelModel.hexPreviewLimit && p.total == raw.count)
        guard case .hex(let h) = p.view else { Issue.record("not hex"); return }
        #expect(h.split(separator: "\n").count == NetworkPanelModel.hexPreviewLimit / 16)
        #expect(NetworkPanelModel.fullBody(f.resBody, text: nil) == raw.base64EncodedString())
        #expect(NetworkPanelModel.fullBody(nil, text: nil) == nil)
    }

    @Test func listMergeKeepsEventsThatArrivedDuringTheFetch() throws {
        let done = try #require(NetworkPanelModel.decode(FlowSummary.self, summary("a", status: 200)))
        let pending = try #require(NetworkPanelModel.decode(FlowSummary.self, summary("a", status: nil, state: .object(["pending": .object([:])]))))
        let new = try #require(NetworkPanelModel.decode(FlowSummary.self, summary("new")))
        let other = FlowRow(serial: "emulator-5556", summary: done), s = "emulator-5554"
        let local = [other, FlowRow(serial: s, summary: done), FlowRow(serial: s, summary: new)]
        let m = NetworkPanelModel.merged(local, [pending], serial: s)
        #expect(m.map(\.id) == ["a", "a", "new"] && m[0].serial == "emulator-5556")
        #expect(m[1].summary.status == 200)   // not back to pending
        #expect(NetworkPanelModel.merged([FlowRow(serial: s, summary: pending)], [done], serial: s)[0].summary.status == 200)
    }

    @Test func stopClearsTheSelection() async {
        let m = model(Fake())
        await m.refresh(); await m.toggle()
        await m.select(flow: "old")
        #expect(m.detail != nil)
        await m.toggle()
        #expect(m.selected == nil && m.detail == nil && m.rows.isEmpty)
    }

    @Test func detailErrorClearsTheSelectionAndShowsIt() async {
        let fake = Fake(), m = model(fake); m.serial = "emulator-5554"
        await fake.set(failure: ProtocolError(code: .notFound, message: "No flow 'a' on emulator-5554"))
        await m.select(flow: "a")
        #expect(m.selected == nil && m.detail == nil && m.error == "No flow 'a' on emulator-5554")
    }

    @Test func clearDropsOnlyThatSerialsRows() async {
        let m = model(Fake()); m.serial = "emulator-5554"
        m.apply(event: "network.flow", payload: summary("a"))
        m.apply(event: "network.flow", payload: summary("b", serial: "emulator-5556"))
        await m.clear()
        #expect(m.rows.map(\.id) == ["b"])
    }

    /// Opt-in: `NETWORK_PANEL_SNAPSHOT=<dir> swift test --filter NetworkPanel` writes light and dark PNGs of the panel.
    @Test func snapshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["NETWORK_PANEL_SNAPSHOT"] else { return }
        let m = model(Fake())
        await m.refresh(); await m.toggle()
        for s in [summary("1", "POST", host: "auth.example.com", path: "/oauth/token", status: 200),
                       summary("2", host: "cdn.example.com", path: "/assets/logo.png", status: 304),
                       summary("3", host: "api.example.com", path: "/v1/items?page=2", status: 200),
                       summary("4", "DELETE", host: "api.example.com", path: "/v1/items/42", status: 404),
                       summary("5", host: "api.example.com", path: "/v1/report", status: 503),
                       summary("6", host: "telemetry.example.com", path: "/collect", status: nil, state: .object(["failed": .object(["_0": .string("TLS handshake failed")])])),
                       summary("7", host: "api.example.com", path: "/v1/stream", status: nil, state: .object(["pending": .object([:])]))] {
            m.apply(event: "network.flow", payload: s)
        }
        func render(_ name: String, _ look: NSAppearance.Name) async throws {
            let v = NSHostingView(rootView: NetworkView(model: m))
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: look)
            w.contentView = v
            v.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            v.layoutSubtreeIfNeeded()
            let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("network-panel-\(name).png"))
        }
        await m.select(flow: "3")
        try await render("light", .aqua); try await render("dark", .darkAqua)
        await m.select(flow: "big")
        try await render("big-body", .darkAqua)
    }
}
