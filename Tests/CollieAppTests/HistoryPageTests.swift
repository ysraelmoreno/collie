import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieApp

private let t0 = Date(timeIntervalSince1970: 1_763_690_520)
private let utc = TimeZone(identifier: "UTC")!
private let evil = "<script>alert(1)</script> \"><img src=x onerror=alert(2)> javascript:alert(3) &amp; 'q'\nlinha 2 😀"

private func archive(title: String = "Trabalho", events: Int = 0, reconstructed: Bool = false, truncated: Bool = false) -> WorkArchive {
    WorkArchive(id: UUID().uuidString.lowercased(), title: title, paddock: evil, branch: evil, openedAt: t0, closedAt: t0.addingTimeInterval(6840),
                stopReason: "requested",
                tasks: [.init(id: "T1", title: evil, state: "done", tries: 2, failure: evil, commits: ["0123456789abcdef"], evidenceNote: evil)],
                timeline: (0..<events).map { .init(at: t0.addingTimeInterval(Double($0)), task: "T1", kind: "k\($0)", detail: evil) },
                notes: [evil], loopSummary: evil, reconstructed: reconstructed, truncated: truncated)
}

@MainActor struct HistoryPageTests {
    @Test func escapeCoversTheFiveCharacters() {
        #expect(HistoryPage.esc("&<>\"'") == "&amp;&lt;&gt;&quot;&#39;")
        #expect(HistoryPage.esc("&amp;") == "&amp;amp;")
        #expect(HistoryPage.esc("😀\nx") == "😀\nx")
    }

    @Test func workTextShowsAsTextNeverAsMarkup() {
        let h = HistoryPage.html(for: archive(title: evil, events: 3), timeZone: utc)
        #expect(!h.contains("<script"))
        #expect(!h.contains("<img"))
        #expect(h.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(h.contains("&quot;&gt;&lt;img src=x onerror=alert(2)&gt;"))
        #expect(h.contains("javascript:alert(3) &amp;amp; &#39;q&#39;"))
    }

    @Test func selfContained() {
        let h = HistoryPage.html(for: archive(title: evil, events: 5), timeZone: utc)
        #expect(!h.contains("http"))
        #expect(!h.contains("href"))
        #expect(!h.contains("<img") && !h.contains("<a ") && !h.contains("<link") && !h.contains("<iframe"))
        let plain = HistoryPage.html(for: archive(events: 5), timeZone: utc).replacingOccurrences(of: HistoryPage.esc(evil), with: "")   // only our own markup is left
        #expect(!plain.contains("src=") && !plain.contains("href"))
        #expect(h.contains("prefers-color-scheme:dark"))
    }

    @Test func headerTableAndTimeline() {
        let h = HistoryPage.html(for: archive(events: 2), timeZone: utc)
        #expect(h.contains("<h1>Trabalho</h1>"))
        #expect(h.contains("<code>01234567</code>") && !h.contains("0123456789abcdef"))
        #expect(h.contains("1h54"))
        #expect(h.contains("<td>k0</td>") && h.contains("<td>k1</td>"))
    }

    @Test func fiveHundredEventsAllShown() {
        let h = HistoryPage.html(for: archive(events: 500), timeZone: utc)
        #expect(h.components(separatedBy: "<td>k").count - 1 == 500)
        #expect(h.contains("<td>k499</td>"))
    }

    @Test func warnings() {
        #expect(!HistoryPage.html(for: archive()).contains("class=\"warn\""))
        #expect(HistoryPage.html(for: archive(truncated: true)).contains("cortada"))
        #expect(HistoryPage.html(for: archive(reconstructed: true)).contains("reconstruído"))
    }

    @Test func filePathIsOnlyAUUID() throws {
        let dir = URL(fileURLWithPath: "/tmp/x/history")
        let id = UUID().uuidString
        let u = try #require(HistoryPage.fileURL(id: id, in: dir))
        #expect(u.deletingLastPathComponent().path == dir.path)
        #expect(u.lastPathComponent.range(of: "^[0-9a-f-]{36}\\.html$", options: .regularExpression) != nil)
        #expect(HistoryPage.fileURL(id: "../../etc/passwd", in: dir) == nil)
        #expect(HistoryPage.fileURL(id: evil, in: dir) == nil)
    }

    @Test func archiveDecodesToleratingBadFields() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let a = try d.decode(WorkArchive.self, from: Data(#"{"id":"x","title":5,"tasks":"no","future":1,"timeline":[{"kind":"k"}]}"#.utf8))
        #expect(a.id == "x" && a.title == "" && a.tasks.isEmpty && a.timeline.count == 1)
    }

    private func opener(fail: Bool = false, opened: Box, dir: URL) -> HistoryOpener {
        HistoryOpener(dir: dir, fetch: { id in
            if fail { throw ProtocolError(code: .internal, message: "x") }
            return WorkArchive(id: id, title: evil)
        }, open: { url in opened.urls.append(url); return opened.panel }, isOpen: { opened.live.contains($0) }, focus: { opened.focused.append($0) })
    }
    final class Box { var urls: [URL] = []; var focused: [UUID] = []; var live: Set<UUID> = []; let panel = UUID() }

    @Test func hookWritesAndOpensOnceThenReusesThePanel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID())")
        let box = Box(); let o = opener(opened: box, dir: dir)
        let id = UUID().uuidString.lowercased()
        await o.show(id)
        #expect(box.urls == [dir.appendingPathComponent("\(id).html")])
        let text = try String(contentsOf: box.urls[0], encoding: .utf8)
        #expect(text.contains("&lt;script&gt;") && !text.contains("<script"))
        box.live.insert(box.panel)
        await o.show(id)
        #expect(box.urls.count == 1 && box.focused == [box.panel])
    }

    @Test func daemonFailureIsAShortNoticeNotACrash() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID())")
        let box = Box(); let o = opener(fail: true, opened: box, dir: dir)
        await o.show(UUID().uuidString.lowercased())
        #expect(box.urls.isEmpty && o.message != nil)
        await o.show("../x")
        #expect(box.urls.isEmpty && o.message == "Histórico: id inválido")
    }
}
