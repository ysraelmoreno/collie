import Testing
@testable import CollieDaemonKit

@Suite struct CollieOrientationTests {
    private func text(shepherd: Bool = false, paddock: String? = nil, peers: [String] = [], panels: [(name: String, pluginId: String)] = []) -> String {
        CollieOrientation.text(terminal: "Ana", isShepherd: shepherd, paddock: paddock, peers: peers, panels: panels)
    }

    @Test func orientationFollowsReach() {
        let none = text()
        #expect(none.hasPrefix("You are running inside Collie, terminal \"Ana\"."))
        #expect(!none.contains("Design panel") && !none.contains("Browser panel") && !none.contains("As Shepherd"))
        #expect(none.contains("collie panel open browser [--url <url>] [--visible]") && !none.contains("design --file") && !text(shepherd: true).contains("Your own test browsers"))
        #expect(none.contains("none yet") && none.contains("Artifacts: collie artifact"))
        #expect(none.contains("collie work task defer <task> \"<reason>\"") && none.contains("collie work done") && text(shepherd: true).contains("collie work status"))
        let d = text(paddock: "F1", peers: ["Bob"], panels: [("Home", "design")])
        #expect(d.contains("Design panel \"Home\"") && d.contains("Do not use other design editors") && d.contains("on paddock \"F1\"") && d.contains("(\"Bob\")"))
        let m = text(shepherd: true)
        #expect(m.contains("collie panel open") && m.contains("design --file <name>") && m.contains("browser --url <url>") && m.contains("device [--serial <id|avd:<name>>]"))
        #expect(!m.contains("Design panel"))
    }

    @Test func shepherdContextMentionsHerds() {
        let m = text(shepherd: true)
        #expect(m.contains("collie herd list") && m.contains("apply <id> --name <n>") && m.contains("save <name> --terminals"))
        #expect(!text().contains("herd"))
    }

    @Test func orientationIsBounded() {
        let ps = ["design", "browser", "device"].flatMap { id in (1...20).map { (name: "\(id)-" + String(repeating: "x", count: 60) + "\($0)", pluginId: id) } }
        let t = text(shepherd: true, paddock: String(repeating: "f", count: 80), peers: (1...20).map { "peer\($0)" }, panels: ps)
        #expect(t.count <= 1300, "\(t.count)")
        #expect(t.contains("more"))
        #expect(text(panels: (1...5).map { (name: "W\($0)", pluginId: "browser") }).contains("\"W3\" +2 more"))
        #expect(!t.contains(String(repeating: "x", count: 41)))
    }

    @Test func orientationHasNoSecrets() {
        let t = text(shepherd: true, peers: ["Bob"], panels: [("Home", "design"), ("Web", "browser")])
        for bad in ["collie-design://", "#join=", "token", "COLLIE_TOKEN", "/hooks/"] { #expect(!t.contains(bad), "\(bad)") }
    }

    @Test func orientationSanitizesNames() {
        let bad = "a\nb\"c", nl = String(repeating: "\n", count: 40)
        let plain = text(shepherd: true, peers: ["p"], panels: [("q", "design"), ("r", "browser")])
        let t = text(shepherd: true, peers: [bad, nl], panels: [(bad, "design"), (nl, "browser")])
        #expect(t.split(separator: "\n", omittingEmptySubsequences: false).count == plain.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(t.contains("\"a bc\""))
        for l in t.split(separator: "\n") where l.hasPrefix("- Design panel") { #expect(l.filter { $0 == "\"" }.count == 2) }
    }
}
