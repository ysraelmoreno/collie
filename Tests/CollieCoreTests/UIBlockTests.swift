import Testing
import Foundation
@testable import CollieCore

@Suite struct UIBlockTests {
    @Test func everyKindParses() {
        #expect(UIBlock.parse(#"{"kind":"table","title":"Pods","columns":["nome","status"],"rows":[["api","Running"],["db",3]]}"#)
                == .table(title: "Pods", columns: ["nome", "status"], rows: [["api", "Running"], ["db", "3"]]))
        #expect(UIBlock.parse(#"{"kind":"diff","old":"a","new":"b"}"#) == .diff(title: nil, old: "a", new: "b"))
        #expect(UIBlock.parse(#"{"kind":"tasks","items":["x",{"text":"y","done":true}]}"#)
                == .tasks(title: nil, items: [.init(text: "x", done: false), .init(text: "y", done: true)]))
        #expect(UIBlock.parse(#"{"kind":"status","items":[["cpu","3%"],{"key":"mem","value":"1G"}]}"#)
                == .status(title: nil, items: [.init(key: "cpu", value: "3%"), .init(key: "mem", value: "1G")]))
        #expect(UIBlock.parse(#"{"kind":"form","question":"Qual?","choices":["a","b"]}"#) == .form(title: nil, question: "Qual?", choices: ["a", "b"]))
        #expect(UIBlock.parse(#"{"kind":"chart","type":"line","labels":["a","b"],"values":[1,2.5]}"#)
                == .chart(title: nil, type: .line, labels: ["a", "b"], values: [1, 2.5]))
        #expect(UIBlock.parse(#"{"kind":"chart","values":[1,2]}"#) == .chart(title: nil, type: .bar, labels: ["1", "2"], values: [1, 2]))
    }

    @Test func badShapesAreNotBlocks() {
        for bad in ["not json", "[]", #"{"kind":"video"}"#, #"{"kind":"table","columns":[],"rows":[]}"#, #"{"kind":"table","columns":["a"],"rows":[[{"x":1}]]}"#,
                    #"{"kind":"form","choices":["only"]}"#, #"{"kind":"chart","values":[1,"2"]}"#, #"{"kind":"chart","values":[1,2],"labels":["a"]}"#,
                    #"{"kind":"chart","values":[true]}"#, #"{"kind":"diff"}"#] {
            #expect(UIBlock.parse(bad) == nil, "\(bad)")
        }
        // caps: more than 500 points, more than 200 rows, a huge document
        #expect(UIBlock.parse(#"{"kind":"chart","values":[\#((0...500).map(String.init).joined(separator: ","))]}"#) == nil)
        #expect(UIBlock.parse(#"{"kind":"table","columns":["a"],"rows":[\#(Array(repeating: #"["x"]"#, count: 201).joined(separator: ","))]}"#) == nil)
        #expect(UIBlock.parse(#"{"kind":"diff","new":"\#(String(repeating: "x", count: 70_000))"}"#) == nil)
    }

    @Test func splitKeepsTextAndTurnsBadFencesIntoCode() {
        let reply = "Aqui:\n```collie-ui\n{\"kind\":\"status\",\"items\":[[\"a\",\"b\"]]}\n```\nE:\n```collie-ui\n{\"kind\":\"nope\"}\n```\nfim"
        let s = ChatSegment.split(reply)
        #expect(s.count == 5)
        #expect(s[0] == .text("Aqui:") && s[3] == .code("{\"kind\":\"nope\"}") && s[4] == .text("fim"))
        guard case .ui(let b, let json) = s[1] else { Issue.record("\(s)"); return }
        #expect(b == .status(title: nil, items: [.init(key: "a", value: "b")]) && json.contains("\"status\""))
        #expect(s[2] == .text("E:"))
        // other fences and plain text are untouched; an unclosed collie-ui fence stays text
        #expect(ChatSegment.split("```swift\nlet x = 1\n```") == [.text("```swift\nlet x = 1\n```")])
        #expect(ChatSegment.split("a\n```collie-ui\n{\"kind\":\"sta") == [.text("a\n```collie-ui\n{\"kind\":\"sta")])
    }

    @Test func sourceNamesAnAppCommand() {
        let j = #"{"kind":"status","items":[["a","b"]],"source":{"app":"kube","command":"pods","params":{"namespace":"default","limit":5,"all":true},"refresh":1}}"#
        #expect(UIBlockSource.parse(j) == UIBlockSource(app: "kube", command: "pods",
                params: ["namespace": .string("default"), "limit": .number(5), "all": .bool(true)], refresh: 5))   // refresh: at least 5 s
        #expect(UIBlockSource.parse(#"{"kind":"status","items":[],"source":{"app":"kube","command":"pods","refresh":99999}}"#)?.refresh == 3600)
        #expect(UIBlockSource.parse(#"{"kind":"status","items":[],"source":{"app":"kube","command":"pods"}}"#)?.refresh == nil)
        for bad in [#"{"kind":"status"}"#, #"{"source":{"app":"kube"}}"#, #"{"source":{"app":"a b","command":"x"}}"#, #"{"source":{"app":"k","command":"x","params":{"p":[1]}}}"#,
                    #"{"source":{"app":"k","command":"x","params":"no"}}"#] {
            #expect(UIBlockSource.parse(bad) == nil, "\(bad)")
        }
        // the block itself is unchanged by a source
        #expect(UIBlock.parse(j) == .status(title: nil, items: [.init(key: "a", value: "b")]))
    }
}
