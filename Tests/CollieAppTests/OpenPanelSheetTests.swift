import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieApp

@Suite(.appCuratorPT) struct OpenPanelSheetTests {
    @Test func previewNeedsATarget() {
        let m = OpenPanelTarget(plugin: "preview")
        #expect(m.needsTarget)
        #expect(!m.canOpen)
        #expect(m.missingHint == "Escolha um artifact ou um arquivo HTML.")
        #expect(m.args.isEmpty)
    }

    @Test func previewWithArtifactOrFileCanOpen() {
        var m = OpenPanelTarget(plugin: "preview", artifactId: "ABC")
        #expect(m.canOpen && m.missingHint == nil)
        #expect(m.args == ["artifact": .string("ABC")])
        m = OpenPanelTarget(plugin: "preview", filePath: "/p/a.html")
        #expect(m.canOpen)
        #expect(m.args == ["file": .string("/p/a.html")])
    }

    @Test func blankTargetsCountAsNone() {
        #expect(!OpenPanelTarget(plugin: "preview", artifactId: "", filePath: "").canOpen)
    }

    @Test func otherPluginsAreAsBefore() {
        for p in ["browser", "terminal", "device", "design", "work"] {
            let m = OpenPanelTarget(plugin: p)
            #expect(!m.needsTarget); #expect(m.canOpen); #expect(m.args.isEmpty); #expect(m.missingHint == nil)
        }
        #expect(OpenPanelTarget(plugin: "browser", artifactId: "x").args.isEmpty)
    }

    @Test func failuresBecomePortuguese() {
        let raw = ProtocolError(code: .invalidArgs, message: "preview: give --file <page.html> or --artifact <id>")
        let t = OpenPanelTarget.failureText(raw)
        #expect(t == "Escolha um artifact ou um arquivo HTML para abrir a Prévia.")
        for c: ErrorCode in [.invalidArgs, .notFound, .unauthorized, .timeout, .internal, .daemonUnavailable] {
            let s = OpenPanelTarget.failureText(ProtocolError(code: c, message: "ProtocolError raw english"))
            #expect(!s.contains("ProtocolError") && !s.contains("raw english") && !s.contains("give --file"))
        }
    }

    /// The daemon's "give --file or --artifact" refusal is matched by its fixed prefix, whatever language its text is in.
    @Test func previewUsageIsMatchedByPrefix() {
        for tail in ["give --file <page.html> or --artifact <id>", "informe --file <page.html> ou --artifact <id>"] {
            let t = L10n.$override.withValue(.en) { OpenPanelTarget.failureText(ProtocolError(code: .invalidArgs, message: "preview: " + tail)) }
            #expect(t == "Pick an artifact or an HTML file to open the Preview.")
        }
    }

    /// M6.5 (A9): a page outside the project says so, in a fixed text (never the daemon's path).
    @Test func aPageOutsideTheProjectSaysSo() {
        let raw = ProtocolError(code: .invalidArgs, message: "a página precisa ficar dentro do projeto /Users/x/p: /tmp/a.html")
        #expect(OpenPanelTarget.failureText(raw) == "A página precisa ficar dentro do projeto.")
        #expect(OpenPanelTarget.failureText(ProtocolError(code: .invalidArgs, message: "other")) == "Não foi possível abrir o painel com essas opções.")
    }
}

@Suite(.appCuratorEN) struct OpenPanelSheetEnglishTests {
    @Test func failuresAreEnglish() {
        #expect(OpenPanelTarget.failureText(ProtocolError(code: .notFound, message: "x")) == "Couldn't find the chosen artifact or file.")
        #expect(OpenPanelTarget.failureText(ProtocolError(code: .timeout, message: "x")) == "The panel took too long to open. Try again.")
        #expect(OpenPanelTarget(plugin: "preview").missingHint == "Pick an artifact or an HTML file.")
    }
}
