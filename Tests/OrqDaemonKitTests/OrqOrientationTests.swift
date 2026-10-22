import Testing
@testable import OrqDaemonKit

@Suite struct OrqOrientationTests {
    private func text(maestro: Bool = false, floor: String? = nil, peers: [String] = [], panels: [(name: String, pluginId: String)] = []) -> String {
        OrqOrientation.text(terminal: "Ana", isMaestro: maestro, floor: floor, peers: peers, panels: panels)
    }

    @Test func orientationFollowsReach() {
        let none = text()
        #expect(none.hasPrefix("You are running inside Orq, terminal \"Ana\"."))
        #expect(!none.contains("Design panel") && !none.contains("Browser panel") && !none.contains("orq panel open") && !none.contains("As Maestro"))
        #expect(none.contains("none yet") && none.contains("Artifacts: orq artifact"))
        #expect(none.contains("orq work task defer <task> \"<reason>\"") && none.contains("orq work done") && text(maestro: true).contains("orq work status"))
        let d = text(floor: "F1", peers: ["Bob"], panels: [("Home", "design")])
        #expect(d.contains("Design panel \"Home\"") && d.contains("Do not use other design editors") && d.contains("on floor \"F1\"") && d.contains("(\"Bob\")"))
        let m = text(maestro: true)
        #expect(m.contains("orq panel open") && m.contains("design --file <name>") && m.contains("browser --url <url>") && m.contains("device [--serial <id|avd:<name>>]"))
        #expect(!m.contains("Design panel"))
    }

    @Test func maestroContextMentionsPartituras() {
        let m = text(maestro: true)
        #expect(m.contains("orq partitura list") && m.contains("apply <id> --name <n>") && m.contains("save <name> --terminals"))
        #expect(!text().contains("partitura"))
    }

    @Test func orientationIsBounded() {
        let ps = ["design", "browser", "device"].flatMap { id in (1...20).map { (name: "\(id)-" + String(repeating: "x", count: 60) + "\($0)", pluginId: id) } }
        let t = text(maestro: true, floor: String(repeating: "f", count: 80), peers: (1...20).map { "peer\($0)" }, panels: ps)
        #expect(t.count <= 1200, "\(t.count)")
        #expect(t.contains("more"))
        #expect(text(panels: (1...5).map { (name: "W\($0)", pluginId: "browser") }).contains("\"W3\" +2 more"))
        #expect(!t.contains(String(repeating: "x", count: 41)))
    }

    @Test func orientationHasNoSecrets() {
        let t = text(maestro: true, peers: ["Bob"], panels: [("Home", "design"), ("Web", "browser")])
        for bad in ["orq-design://", "#join=", "token", "ORQ_TOKEN", "/hooks/"] { #expect(!t.contains(bad), "\(bad)") }
    }

    @Test func orientationSanitizesNames() {
        let bad = "a\nb\"c", nl = String(repeating: "\n", count: 40)
        let plain = text(maestro: true, peers: ["p"], panels: [("q", "design"), ("r", "browser")])
        let t = text(maestro: true, peers: [bad, nl], panels: [(bad, "design"), (nl, "browser")])
        #expect(t.split(separator: "\n", omittingEmptySubsequences: false).count == plain.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(t.contains("\"a bc\""))
        for l in t.split(separator: "\n") where l.hasPrefix("- Design panel") { #expect(l.filter { $0 == "\"" }.count == 2) }
    }
}
