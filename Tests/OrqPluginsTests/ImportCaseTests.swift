// A real import case, end to end on this machine (WebKit snapshot → mapper → figcraft-cli run → render), for
// pages that must stay out of the repo:
//   ORQ_IMPORT_CASE=<folder of .html pages> swift test --filter ImportCaseTests
// Per page `<name>.html` it writes `<folder>/../out/{<name>.png, source-<name>.png, <name>.figcraft, <name>.txt}`
// (the .txt: step count and warnings). Width: 390 when the name contains "mobile", else 1440.
import AppKit
import Foundation
import Testing
import WebKit
import OrqProtocol
@testable import OrqPlugins
@testable import OrqDaemonKit

private let caseDir = ProcessInfo.processInfo.environment["ORQ_IMPORT_CASE"].map { URL(fileURLWithPath: $0) }
private let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("vendor/figcraft/bin/figcraft-cli")

@MainActor @Suite(.serialized) struct ImportCaseTests {
    @Test(.enabled(if: caseDir != nil), .timeLimit(.minutes(10)))
    func importCase() async throws {
        let dir = try #require(caseDir), out = dir.deletingLastPathComponent().appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pages = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".html") }.sorted()
        for page in pages {
            let name = String(page.dropLast(5)), width = name.contains("mobile") ? 390 : 1440
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("case-\(UUID().uuidString)/artifacts")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let id = UUID().uuidString.lowercased(), source = root.appendingPathComponent("\(id)/source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: dir.appendingPathComponent(page), to: source.appendingPathComponent(page))
            let url = URL(string: "orq-artifact://app/\(id)/source/\(page)")!

            _ = try await HTMLSnapshotter.handle(command: "html.snapshot",
                                                 args: ["id": .string(id), "url": .string(url.absoluteString), "width": .number(Double(width))],
                                                 artifactsRoot: root, timeoutSeconds: 60)
            let imp = root.appendingPathComponent("\(id)/.import")
            let snap = try JSONDecoder().decode(DOMSnapshot.self, from: Data(contentsOf: imp.appendingPathComponent("snapshot.json")))
            var payloads: [String: Data] = [:]
            for f in try FileManager.default.contentsOfDirectory(atPath: imp.path) where f != "snapshot.json" {
                payloads[f] = try Data(contentsOf: imp.appendingPathComponent(f))
            }

            // the FontBook as the daemon builds it: the engine's styles of the page's first families (+ Inter)
            var families: Set<String> = ["Inter"]
            func walk(_ n: OrqDaemonKit.DOMNode) {
                if let first = n.style["fontFamily"]?.split(separator: ",").first {
                    families.insert(first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                }
                n.children.forEach(walk)
            }
            walk(snap.root)
            let have = strings(try await run([cmd("text.fonts", [:])], out).first ?? .null)
            let wanted = have.filter { f in families.contains { $0.caseInsensitiveCompare(f) == .orderedSame } }
            var book = FontBook(families: [:])
            for (f, r) in zip(wanted, try await run(wanted.map { cmd("text.fonts", ["family": .string($0)]) }, out)) { book.families[f] = strings(r) }

            let (steps, warnings, _) = HTMLImport.steps(snap, payloads: payloads, fonts: book, name: name)
            let fig = out.appendingPathComponent("\(name).figcraft")
            let results = try await run(steps, out, save: fig)
            let failed = results.enumerated().filter { $0.element == .null }.map(\.offset)
            let png = out.appendingPathComponent("\(name).png")
            let r = try await BoundedProcess.run(executable: cli, args: ["render", fig.path, "-o", png.path], in: out, env: [:], timeout: .seconds(120))
            #expect(r.status == 0, "\(r.stderr)")
            let report = (["steps: \(steps.count)", "failed steps: \(failed)", "fonts: \(book.families)", "warnings:"] + warnings).joined(separator: "\n")
            try Data(report.utf8).write(to: out.appendingPathComponent("\(name).txt"))
            try await shoot(url, root: root, width: width, height: Int(snap.height), to: out.appendingPathComponent("source-\(name).png"))
        }
    }

    private func cmd(_ c: String, _ p: [String: JSONValue]) -> JSONValue { .object(["command": .string(c), "params": .object(p)]) }
    private func strings(_ v: JSONValue) -> [String] {
        if case .array(let a) = v { a.compactMap { if case .string(let s) = $0 { s } else { nil } } } else { [] }
    }
    /// `figcraft-cli run`: each step's `result` (`.null` when the step failed).
    private func run(_ steps: [JSONValue], _ dir: URL, save: URL? = nil) async throws -> [JSONValue] {
        let script = dir.appendingPathComponent("script.json")
        try JSONEncoder().encode(steps).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        let r = try await BoundedProcess.run(executable: cli, args: ["run", script.path] + (save.map { ["--out", $0.path] } ?? []),
                                             in: dir, env: [:], timeout: .seconds(300), cap: 64 << 20)
        #expect(r.status == 0, "\(r.stderr)")
        return r.stdout.split(separator: "\n").map {
            guard case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)), o["ok"] == .bool(true) else { return .null }
            return o["result"] ?? .object([:])
        }
    }

    /// The source page as WebKit draws it (network blocked like the snapshot), full height.
    private func shoot(_ url: URL, root: URL, width: Int, height: Int, to file: URL) async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(DesignSchemeHandler(root: root, artifacts: true), forURLScheme: BrowserPanel.artifactScheme)
        if let rules = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "orq-case-offline",
                                                                                         encodedContentRuleList: HTMLSnapshotter.ruleJSON) {
            config.userContentController.add(rules)
        }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: max(height, 1)), configuration: config)
        web.load(URLRequest(url: url))
        repeat { try await Task.sleep(for: .milliseconds(200)) } while web.isLoading
        try await Task.sleep(for: .seconds(1))   // ponytail: settle time for layout/fonts; poll document.fonts if it flakes
        let image = try await web.takeSnapshot(configuration: nil)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)
    }
}
