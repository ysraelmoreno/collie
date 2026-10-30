import Testing
import Foundation
@testable import CollieProtocol

@Suite struct CommandsTests {
    @Test func pluginCommandGroupWord() throws {
        let r = try ArgvParser.parse(["artifact", "add", "--path", "a.html"])
        #expect(r.command == "artifact.add" && r.args["path"] == .string("a.html"))
    }

    @Test func artifactMoveTakesManyIds() throws {
        let r = try ArgvParser.parse(["artifact", "move", "a", "b", "c", "--folder", "Cliente"])
        #expect(r.args == ["ids": .array([.string("a"), .string("b"), .string("c")]), "folder": .string("Cliente")])
        #expect(throws: ProtocolError.self) { try ArgvParser.parse(["artifact", "move", "--folder", "Cliente"]) }
        let tool = MCPSchema.tools().first { if case .object(let o) = $0 { o["name"] == .string("artifact_move") } else { false } }
        guard case .object(let o)? = tool, case .object(let schema)? = o["inputSchema"], case .object(let props)? = schema["properties"],
              case .object(let ids)? = props["ids"] else { Issue.record("\(String(describing: tool))"); return }
        #expect(ids["type"] == .string("array") && ids["items"] == .object(["type": .string("string")]))
        #expect(schema["required"] == .array([.string("ids"), .string("folder")]))
    }

    @Test func connectRepeatsIntoACommaList() throws {
        let r = try ArgvParser.parse(["summon", "d1", "--preset", "claude", "--connect", "design-1", "--connect", "a,b"])
        #expect(r.args["connect"] == .string("design-1,a,b"))
        let o = try ArgvParser.parse(["panel", "open", "design", "--file", "F", "--connect", "d1"])
        #expect(o.command == "panel.open" && o.args["connect"] == .string("d1"))
    }

    @Test func parsesAskResultAndNoWait() throws {
        let r = try ArgvParser.parse(["ask", "result", "ab12cd34"])
        #expect(r.command == "ask.result" && r.args["id"] == .string("ab12cd34"))
        #expect(try ArgvParser.parse(["ask", "result"]).command == "ask.result")
        let n = try ArgvParser.parse(["ask", "B", "do", "it", "--no-wait"])
        #expect(n.command == "ask" && n.args["target"] == .string("B") && n.args["no-wait"] == .bool(true))
    }

    @Test func parsesAskWithRestPrompt() throws {
        let r = try ArgvParser.parse(["ask", "Reviewer", "revise", "o", "PR", "--raw"])
        #expect(r.command == "ask")
        #expect(r.args["target"] == .string("Reviewer"))
        #expect(r.args["prompt"] == .string("revise o PR"))
        #expect(r.args["raw"] == .bool(true))
    }

    @Test func parsesCheckIntFlag() throws {
        let r = try ArgvParser.parse(["check", "Bob", "--lines", "50"])
        #expect(r.args["lines"] == .number(50))
    }

    @Test(arguments: ["abc", "1.5", "nan", "inf", "1e999"])
    func rejectsNonIntegerInt(_ v: String) {
        let e = #expect(throws: ProtocolError.self) { try ArgvParser.parse(["check", "Bob", "--lines", v]) }
        #expect(e?.code == .invalidArgs)
        #expect(e?.message.contains("lines") == true)
    }

    @Test func parsesDoubleDashTerminator() throws {
        let a = try ArgvParser.parse(["ask", "Bob", "--", "explain", "--foo", "please"])
        #expect(a.args["target"] == .string("Bob"))
        #expect(a.args["prompt"] == .string("explain --foo please"))
        let b = try ArgvParser.parse(["ask", "Bob", "--raw", "--", "hi", "--x"])
        #expect(b.args["raw"] == .bool(true))
        #expect(b.args["prompt"] == .string("hi --x"))
    }

    @Test func parsesAdminSubcommand() throws {
        let r = try ArgvParser.parse(["admin", "spawn", "A", "--preset", "shell"])
        #expect(r.command == "admin.spawn")
        #expect(r.args["name"] == .string("A"))
        #expect(r.args["preset"] == .string("shell"))
        let f = try ArgvParser.parse(["paddock", "status", "feat", "review"])
        #expect(f.command == "paddock.status" && f.args["name"] == .string("feat") && f.args["status"] == .string("review"))
        let m = try ArgvParser.parse(["memory", "save", "--kind", "decision", "--subject", "db", "--title", "Postgres", "for", "jsonb"])
        #expect(m.command == "memory.save" && m.args["body"] == .string("for jsonb") && m.args["title"] == .string("Postgres"))
    }

    @Test func parsesPluginAndPanelSubcommands() throws {
        let n = try ArgvParser.parse(["browser", "navigate", "https://x.dev", "--panel", "web"])
        #expect(n.command == "browser.navigate" && n.args == ["url": .string("https://x.dev"), "panel": .string("web")])
        let f = try ArgvParser.parse(["browser", "fill", "e3", "hello", "world"])
        #expect(f.args == ["ref": .string("e3"), "text": .string("hello world")])
        let o = try ArgvParser.parse(["panel", "open", "browser", "--placement", "canvas"])
        #expect(o.command == "panel.open" && o.args["plugin"] == .string("browser") && o.args["placement"] == .string("canvas"))
        #expect(try ArgvParser.parse(["events", "--since", "4"]).args == ["since": .number(4)])
    }

    @Test func rejectsBadDottedSubcommands() {
        for argv in [["panel"], ["panel", "bogus"], ["browser", "bogus"], ["browser"], ["panel", "close"]] {
            let e = #expect(throws: ProtocolError.self) { try ArgvParser.parse(argv) }
            #expect(e?.code == .invalidArgs, "\(argv)")
        }
    }

    @Test func rejectsUnknownCommand() {
        let e = #expect(throws: ProtocolError.self) { try ArgvParser.parse(["bogus"]) }
        #expect(e?.code == .invalidArgs)
        #expect(e?.message.contains("bogus") == true)
    }

    @Test func rejectsMissingRequired() {
        let e = #expect(throws: ProtocolError.self) { try ArgvParser.parse(["ask"]) }
        #expect(e?.code == .invalidArgs)
        #expect(e?.message.contains("target") == true)
    }

    @Test func threeWordPluginCommandsParse() throws {
        let p = try ArgvParser.parse(["design", "system", "create", "Brand", "--from", "Base", "--reason", "why"])
        #expect(p.command == "design.system.create" && p.args == ["name": .string("Brand"), "from": .string("Base"), "reason": .string("why")])
        #expect(try ArgvParser.parse(["design", "system", "list"]).command == "design.system.list")
        let w = try ArgvParser.parse(["work", "task", "defer", "Write docs", "waits", "for", "API"])
        #expect(w.command == "work.task.defer" && w.args == ["task": .string("Write docs"), "reason": .string("waits for API")])
        #expect(try ArgvParser.parse(["work", "clear-history"]).command == "work.clear-history")
        #expect(throws: ProtocolError.self) { try ArgvParser.parse(["design", "system"]) }
    }

    @Test func mcpSchemaOmitsInternalCommands() {
        let tools = MCPSchema.tools()
        let names = tools.compactMap { t -> String? in
            if case .object(let o) = t, case .string(let n)? = o["name"] { return n } else { return nil }
        }.filter(builtInTool)
        #expect(names == ["list", "ask", "ask_result", "check", "paddock_list", "paddock_status", "panel_open", "panel_close", "panel_move", "panel_list", "events",
                         "memory_save", "memory_search", "memory_list", "memory_get", "memory_context", "memory_checklist", "memory_promote", "memory_stats",
                         "work_start", "work_done", "work_reopen", "work_task_add", "work_task_done", "work_task_defer", "work_task_drop", "work_note", "work_status", "work_summary", "work_list", "work_get",
                         "lot_leave", "lot_list", "lot_get", "lot_post", "lot_board", "comment_reply", "comment_list", "access_request", "access_list", "font_add", "font_list",
                         "browser_navigate", "browser_snapshot", "browser_click", "browser_hover", "browser_fill", "browser_type", "browser_key", "browser_scroll", "browser_eval", "browser_text", "browser_wait", "browser_screenshot", "browser_console", "browser_resize", "browser_emulate", "browser_reload", "browser_storage", "browser_init-script", "device_list", "device_screenshot", "device_ui", "device_tap", "device_swipe", "device_text", "device_key", "device_logcat", "device_install", "device_launch",
                         "network_attach", "network_detach", "network_status", "network_list", "network_get", "network_curl", "network_clear",
                         "design_files", "design_new", "design_run", "design_batch", "design_inspect", "design_screenshot", "design_export", "design_help", "design_prefer",
                         "design_system_list", "design_system_create", "design_system_publish", "design_system_history", "design_system_use", "design_system_undo", "design_system_revert", "design_system_tokens", "design_system_bind", "design_system_style", "design_system_place", "design_system_mode",
                         "diagram_get", "diagram_set", "diagram_mermaid", "diagram_export", "diagram_screenshot", "preview_get", "preview_screenshot",
                         "artifact_list", "artifact_get", "artifact_add", "artifact_import-claude", "artifact_import-list", "artifact_import-failed", "artifact_import", "artifact_libs", "artifact_new",
                         "artifact_move", "artifact_folders"])
        guard case .object(let ask) = tools[1], case .object(let schema)? = ask["inputSchema"],
              case .array(let req)? = schema["required"] else { Issue.record("bad schema"); return }
        #expect(req.contains(.string("target")) && req.contains(.string("prompt")))
    }

    @Test func mcpSchemaListsShepherdToolsOnlyForShepherd() throws {
        func names(_ m: Bool) -> [String] {
            MCPSchema.tools(shepherd: m).compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { n } else { nil } }.filter(builtInTool)
        }
        #expect(names(true) == ["list", "ask", "ask_result", "check", "summon", "dismiss", "leash", "unleash", "notify",
                                "paddock_create", "paddock_list", "paddock_status", "paddock_land", "paddock_delete", "panel_open", "panel_close", "panel_move", "panel_list", "events",
                                "memory_save", "memory_search", "memory_list", "memory_get", "memory_context", "memory_checklist", "memory_promote", "memory_stats",
                         "work_start", "work_done", "work_reopen", "work_task_add", "work_task_done", "work_task_defer", "work_task_drop", "work_note", "work_status", "work_summary", "work_list", "work_get", "work_rerail",
                         "herd_list", "herd_get", "herd_save", "herd_apply", "lot_create", "lot_join", "lot_leave", "lot_list", "lot_get", "lot_post", "lot_board", "comment_reply", "comment_list", "access_request", "access_list", "font_add", "font_list",
                         "browser_navigate", "browser_snapshot", "browser_click", "browser_hover", "browser_fill", "browser_type", "browser_key", "browser_scroll", "browser_eval", "browser_text", "browser_wait", "browser_screenshot", "browser_console", "browser_resize", "browser_emulate", "browser_reload", "browser_storage", "browser_init-script", "device_list", "device_screenshot", "device_ui", "device_tap", "device_swipe", "device_text", "device_key", "device_logcat", "device_install", "device_launch",
                         "network_attach", "network_detach", "network_status", "network_list", "network_get", "network_curl", "network_clear",
                         "design_files", "design_new", "design_run", "design_batch", "design_inspect", "design_screenshot", "design_export", "design_help", "design_prefer",
                         "design_system_list", "design_system_create", "design_system_publish", "design_system_history", "design_system_use", "design_system_undo", "design_system_revert", "design_system_tokens", "design_system_bind", "design_system_style", "design_system_place", "design_system_mode",
                         "diagram_get", "diagram_set", "diagram_mermaid", "diagram_export", "diagram_screenshot", "preview_get", "preview_screenshot",
                         "artifact_list", "artifact_get", "artifact_add", "artifact_import-claude", "artifact_import-list", "artifact_import-failed", "artifact_import", "artifact_libs", "artifact_new",
                         "artifact_move", "artifact_folders"])
        #expect(try ArgvParser.parse(["summon", "w", "--preset", "shell", "echo", "hi"]).args
                == ["name": .string("w"), "preset": .string("shell"), "prompt": .string("echo hi")])
        // flags anywhere before `--` are flags, not prompt words; after `--` everything is prompt
        #expect(try ArgvParser.parse(["summon", "w", "echo", "hi", "--preset", "shell", "--", "--x"]).args
                == ["name": .string("w"), "preset": .string("shell"), "prompt": .string("echo hi --x")])
    }

    // plan 2O Task 2: `--out` on every command whose reply is a file (`Commands.outputFile`), nowhere else
    @Test func outAcceptedForDesignScreenshot() throws {
        let r = try ArgvParser.parse(["design", "screenshot", "--panel", "d", "--out", "shot.png"])
        #expect(r.command == "design.screenshot" && r.args["out"] == .string("shot.png"))
    }

    @Test func outAcceptedForDesignExport() throws {
        let r = try ArgvParser.parse(["design", "export", "--format", "css", "--out", "x.css"])
        #expect(r.command == "design.export" && r.args["out"] == .string("x.css"))
        for c in Commands.outputFile {   // the set and the specs agree
            #expect(Commands.spec(c)?.params.contains { $0.name == "out" && $0.kind == .string } == true, "\(c)")
        }
    }

    @Test func outRejectedForOtherCommands() {
        for argv in [["design", "inspect", "--out", "x"], ["memory", "get", "--out", "x"]] {
            let e = #expect(throws: ProtocolError.self) { try ArgvParser.parse(argv) }
            #expect(e?.message == "unknown flag --out", "\(argv)")
        }
        #expect(Commands.all.filter { $0.params.contains { $0.name == "out" } }.map(\.name).filter { !Commands.outputFile.contains($0) }
                == ["admin.data.export"])   // its own --out: the daemon writes the backup
    }

    // final review F6: a source the caller can't read is "cannot read", not "cannot write"
    @Test func outReadFailureSaysCannotRead() {
        let src = "/nonexistent-\(UUID().uuidString)/p.png"
        let e = #expect(throws: ProtocolError.self) {
            try OutFile.copyPath(of: .object(["path": .string(src)]), to: "x.png", cwd: FileManager.default.temporaryDirectory.path)
        }
        #expect(e?.message == "--out: cannot read \(src)", "\(String(describing: e))")
    }
}

/// A built-in's tool: another suite may have external plug-ins registered in this process meanwhile (the registry is
/// process-wide), whose tools come after these.
private func builtInTool(_ name: String) -> Bool { Commands.reservedPluginIds.contains(String(name.prefix { $0 != "_" })) }
