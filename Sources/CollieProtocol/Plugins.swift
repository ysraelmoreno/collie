/// Lives in CollieProtocol (not CollieCore) because PluginSpec references it and CollieCore depends on CollieProtocol.
/// `headless`: a browser hosted but never shown (no canvas node, not in a dock); see `panel.open`.
public enum PanelPlacement: String, Codable, Sendable {
    case dockLeft = "dock.left", dockRight = "dock.right", dockBottom = "dock.bottom", canvas, headless
    /// ponytail: a placement this build doesn't know (a newer one's) loads as `canvas` instead of failing the whole workspace.
    public init(from d: Decoder) throws { self = PanelPlacement(rawValue: try d.singleValueContainer().decode(String.self)) ?? .canvas }
}
public enum StorageScope: String, Codable, Sendable { case isolated, workspace, global }   // default .isolated

public struct PluginSpec: Sendable {
    public var id: String; public var title: String
    public var placements: [PanelPlacement]; public var defaultPlacement: PanelPlacement
    public var commands: [CommandSpec]   // named "<id>.<cmd>"; each gets an optional "panel" param
    public var events: [String]
    /// true: the daemon runs the commands itself (adb); false: they are forwarded to the app (`ui.host`).
    public var runsInDaemon: Bool
    public init(id: String, title: String, placements: [PanelPlacement], defaultPlacement: PanelPlacement,
                commands: [CommandSpec], events: [String], runsInDaemon: Bool = false) {
        self.id = id; self.title = title; self.placements = placements; self.defaultPlacement = defaultPlacement
        self.events = events; self.runsInDaemon = runsInDaemon
        self.commands = commands.map { var c = $0; c.params.append(ParamSpec("panel", .string, help: "Panel name (default: the only reachable one)")); return c }
    }
}

public enum PluginRegistry {
    public static let all: [PluginSpec] = [browser, memory, device, design, designsystems, artifacts, work]

    /// Plugin ids a Shepherd can open on the canvas (feeds `panel.open` help and the agent orientation).
    public static var canvasPluginIds: [String] { all.filter { $0.placements.contains(.canvas) }.map(\.id) }

    public static func spec(_ id: String) -> PluginSpec? { all.first { $0.id == id } }
    public static func command(_ name: String) -> (PluginSpec, CommandSpec)? {
        for p in all { if let c = p.commands.first(where: { $0.name == name }) { return (p, c) } }
        return nil
    }

    private static func cmd(_ n: String, _ summary: String, _ params: [ParamSpec] = [], timeout: Double = 30) -> CommandSpec {
        CommandSpec(name: "browser.\(n)", summary: summary, params: params, timeoutSeconds: timeout)
    }

    static let browser = PluginSpec(
        id: "browser", title: "Browser",
        placements: [.dockRight, .dockLeft, .dockBottom, .canvas, .headless], defaultPlacement: .dockRight,
        commands: [
            cmd("navigate", "Load a URL", [ParamSpec("url", .string, positional: true, required: true, help: "URL")]),
            cmd("snapshot", "Compact page tree with element refs (e1, e2, ...)"),
            cmd("click", "Click an element (a real mouse click when the page is in a window; reply trusted: true)", [ParamSpec("ref", .string, positional: true, required: true, help: "Element ref")]),
            cmd("hover", "Move the pointer over an element (:hover applies when the page is in a window)", [ParamSpec("ref", .string, positional: true, required: true, help: "Element ref")]),
            cmd("fill", "Fill an input", [ParamSpec("ref", .string, positional: true, required: true, help: "Element ref"),
                                         ParamSpec("text", .rest, positional: true, required: true, help: "Text")]),
            cmd("type", "Type text into the focused element", [ParamSpec("text", .rest, positional: true, required: true, help: "Text (up to 1024 characters)")]),
            cmd("key", "Press a key", [ParamSpec("key", .string, positional: true, required: true, help: "Enter, Tab, Shift+Tab, Escape, ArrowDown, Meta+a (select all)...; Meta+c/x/v are refused (no clipboard access)")]),
            cmd("scroll", "Scroll an element into view or by dy pixels",
                [ParamSpec("ref", .string, help: "Element ref"), ParamSpec("dy", .int, help: "Vertical pixels")]),
            cmd("eval", "Evaluate JavaScript", [ParamSpec("js", .rest, positional: true, required: true, help: "JavaScript")]),
            cmd("text", "Visible page text"),
            cmd("wait", "Wait for text or a selector",
                [ParamSpec("text", .string, help: "Text to wait for"), ParamSpec("selector", .string, help: "CSS selector"),
                 ParamSpec("timeout", .int, help: "Seconds (default 10, max 120)")], timeout: 120),
            cmd("screenshot", "Screenshot to a PNG file; returns {path, width, height} (pixels at backing scale). --full-page tiles the document by viewport height (max 16384 px tall; content growing during the capture, e.g. lazy/infinite, is cut at the height measured at the start; position:fixed/sticky elements repeat in every tile); --clip x,y,w,h (viewport CSS px) or --ref crops; --out copies the PNG to PATH (written by the collie process, relative to its cwd; for MCP the cwd of `collie mcp`) and returns that path",
                [ParamSpec("full-page", .flag, help: "Whole document, tiled by viewport height"),
                 ParamSpec("clip", .string, help: "x,y,w,h in viewport CSS px"),
                 ParamSpec("ref", .string, help: "Element ref to crop to"),
                 ParamSpec("out", .string, help: "Copy the PNG here (created dirs, overwritten)")]),
            cmd("console", "Recent console lines", [ParamSpec("lines", .int, help: "Lines (default 100, max 500)")]),
            cmd("resize", "Set the page viewport (the panel keeps its size; the page is shown scaled to fit); returns {width, height, scale}",
                [ParamSpec("width", .int, help: "200-4096"), ParamSpec("height", .int, help: "200-4096 (default: the current one)"),
                 ParamSpec("reset", .flag, help: "Back to filling the panel")]),
            cmd("emulate", "Emulate media features until changed; returns {colorScheme, reducedMotion, uncoveredSheets, uncoveredShadowRoots}; reduced motion rewrites readable stylesheets (document, adopted, open shadow roots): uncoveredSheets = unreadable (cross-origin) sheets, uncoveredShadowRoots = closed shadow roots",
                [ParamSpec("color-scheme", .string, help: "light | dark | system"),
                 ParamSpec("reduced-motion", .string, help: "reduce | no-preference | system")]),
            cmd("reload", "Reload the page; --hard bypasses the cache (reloadFromOrigin); returns {url, title}", [ParamSpec("hard", .flag, help: "Revalidate everything with the origin")]),
            cmd("storage", "clear | set | get on the page's origin. clear [--local] [--session] [--cookies] (none = all) empties local/session storage and cookies of THIS panel's data store only: an isolated panel loses all its cookies, a workspace/global panel only the current site's (other panels and sites sharing that store are untouched). set --key K --value V / get --key K use localStorage (the page needs an origin, not about:blank)",
                [ParamSpec("action", .string, positional: true, required: true, help: "clear | set | get"),
                 ParamSpec("local", .flag, help: "clear: localStorage"), ParamSpec("session", .flag, help: "clear: sessionStorage"),
                 ParamSpec("cookies", .flag, help: "clear: cookies (see above)"),
                 ParamSpec("key", .string, help: "set/get: key"), ParamSpec("value", .string, help: "set: value")]),
            cmd("init-script", "add | list | clear: JavaScript run at document start (main frame, page world, before the page's scripts) on every later load of this panel; not run on the current page, kept until the panel closes (not persisted). add --js JS returns {id}; list; clear [--id ID] (none = all)",
                [ParamSpec("action", .string, positional: true, required: true, help: "add | list | clear"),
                 ParamSpec("js", .string, help: "add: JavaScript (up to 64 KiB, at most 32 scripts)"), ParamSpec("id", .string, help: "clear: one script")]),
        ],
        events: ["browser.loaded", "browser.console"])
}

extension PluginRegistry {
    /// The Memory review panel: no agent commands (agents use `collie memory ...`); the app view talks to `memory.*` directly.
    static let memory = PluginSpec(
        id: "memory", title: "Memória",
        placements: [.dockRight, .dockLeft, .dockBottom], defaultPlacement: .dockRight,
        commands: [], events: [])
}

extension PluginRegistry {
    /// The Design Systems panel: no agent commands (agents use `collie design system ...`); the app view talks to `design.system.*` directly.
    static let designsystems = PluginSpec(
        id: "designsystems", title: "Design Systems",
        placements: [.dockRight, .dockLeft, .dockBottom], defaultPlacement: .dockRight,
        commands: [], events: [])
}

extension PluginRegistry {
    private static func dcmd(_ n: String, _ summary: String, _ params: [ParamSpec] = [], timeout: Double, panelFree: Bool = false) -> CommandSpec {
        CommandSpec(name: "device.\(n)", summary: summary, params: params, timeoutSeconds: timeout, panelFree: panelFree)
    }
    private static func coord(_ n: String, _ positional: Bool = true, required: Bool = false) -> ParamSpec {
        ParamSpec(n, .int, positional: positional, required: required, help: "Android pixels or iOS points, 0-100000")
    }

    /// An Android device or emulator through adb, or an iOS Simulator through simctl + AXe; the daemon runs these
    /// commands (no app round trip).
    static let device = PluginSpec(
        id: "device", title: "Dispositivo",
        placements: [.canvas, .dockRight, .dockLeft, .dockBottom], defaultPlacement: .canvas,
        commands: [
            dcmd("list", "Android devices and iOS Simulators [{serial,state,model,product,platform,panels}]; Android AVDs that are off: state off, serial avd:<name> (panel open boots it) (ignores --panel)", timeout: 15, panelFree: true),
            dcmd("screenshot", "Screenshot to a PNG file; returns {path,width,height}, plus on iOS {scale,pointWidth,pointHeight}: iOS taps and swipes use points (see pointWidth/pointHeight), not the PNG's pixels", [out], timeout: 30),
            dcmd("ui", "Compact UI tree with element refs (e1, e2, ...); returns {tree,truncated}", timeout: 30),
            dcmd("tap", "Tap at x y (Android (pixels) or iOS Simulator (points)), or on an element from device.ui",
                 [coord("x"), coord("y"), ParamSpec("ref", .string, help: "Element ref from device.ui")], timeout: 15),
            dcmd("swipe", "Swipe from x1 y1 to x2 y2 (Android (pixels) or iOS Simulator (points))",
                 [coord("x1", required: true), coord("y1", required: true), coord("x2", required: true), coord("y2", required: true),
                  ParamSpec("ms", .int, help: "Duration in ms (1-10000, default 300)")], timeout: 20),
            dcmd("text", "Type ASCII text into the focused field", [ParamSpec("text", .rest, positional: true, required: true, help: "Text")], timeout: 15),
            dcmd("key", "Press a key (Android, or iOS Simulator: Enter, Escape, Backspace, Tab, Space, arrows, Home, Lock or a HID usage)",
                 [ParamSpec("key", .string, positional: true, required: true, help: "Enter, Back, Home, ... or a keycode (iOS: HID usage)")], timeout: 15),
            dcmd("logcat", "Recent log lines",
                 [ParamSpec("lines", .int, help: "Lines (1-2000, default 200)"), ParamSpec("grep", .string, help: "Keep lines containing this text")], timeout: 20),
            dcmd("install", "Install an app: a .apk on Android, a .app bundle on the iOS Simulator (path relative to the current directory)",
                 [ParamSpec("path", .string, positional: true, required: true, help: "Path to a .apk (Android) or .app (iOS Simulator)")], timeout: 300),
            dcmd("launch", "Launch an app",
                 [ParamSpec("package", .string, positional: true, required: true, help: "Package id (Android) or bundle id (iOS)"),
                  ParamSpec("activity", .string, help: "Activity (default: the launcher one; Android only)")], timeout: 30),
        ],
        events: ["device.connected", "device.disconnected", "device.crash", "device.app_launched"],
        runsInDaemon: true)
}

extension PluginRegistry {
    private static func gcmd(_ n: String, _ summary: String, _ params: [ParamSpec] = [], timeout: Double,
                             exposedToMCP: Bool = true, panelFree: Bool = false) -> CommandSpec {
        CommandSpec(name: "design.\(n)", summary: summary, params: params, timeoutSeconds: timeout, exposedToMCP: exposedToMCP, panelFree: panelFree)
    }
    private static let node = ParamSpec("node", .string, help: "Layer id (as design.inspect shows it)")
    /// `--out` of a command in `Commands.outputFile`: the collie process copies the reply's file (`OutFile`).
    private static let out = ParamSpec("out", .string, help: "Copy the file here (relative to the current directory; dirs created, overwritten); returns that path")
    private static let ids = ParamSpec("ids", .string, required: true, help: "Layer ids, comma-separated (as design.inspect shows them)")
    private static let reason = ParamSpec("reason", .string, required: true, help: "Why (kept in the history and as a project decision)")

    /// Design files on the local figcraft server, edited live by the app and the agents; the daemon runs these commands.
    /// A panel holds one file (`state["file"]`); each caller edits it through a figcraft client of its own (own undo).
    static let design = PluginSpec(
        id: "design", title: "Design",
        placements: [.canvas, .dockRight, .dockLeft, .dockBottom], defaultPlacement: .canvas,
        commands: [
            gcmd("files", "Design files [{name,panels}] (ignores --panel)", timeout: 10, panelFree: true),
            gcmd("new", "Create an empty design file on the caller's paddock, with the active design system's library (ignores --panel); returns {name}",
                 [ParamSpec("name", .string, positional: true, required: true, help: "File name (1-80 of A-Z a-z 0-9 space . _ -)"),
                  ParamSpec("paddock", .string, help: "Paddock of the file (app only; default pasture)")], timeout: 60, panelFree: true),
            gcmd("run", "Run one figcraft command (ids and params: design.help); returns its result. Commands never act on the user's selection: pass the layers as ids (or id), don't select them first (commands that work only on the selection are refused); edit.delete, edit.duplicate and object.group with ids [] do nothing and return {\"skipped\": \"no ids\"}",
                 [ParamSpec("command", .string, positional: true, required: true, help: "Command id, e.g. node.create"),
                  ParamSpec("params", .string, help: "JSON object of parameters")], timeout: 60),
            gcmd("batch", "Run figcraft commands as one undo step, all or nothing ({\"$step\": n} names step n's result id, from 0); returns the results. [] does nothing ({\"results\": []}); each step names its layers with ids (or id), as design.run; edit.delete, edit.duplicate and object.group with ids [] are skipped ({\"skipped\": \"no ids\"} in its place)",
                 [ParamSpec("commands", .string, help: "JSON array of {command, params}"),
                  ParamSpec("file", .string, help: "A .json file with that array (relative to the current directory)"),
                  ParamSpec("label", .string, help: "Undo history label")], timeout: 120),
            gcmd("inspect", "The document (pages and layers), or one layer with --node",
                 [node, ParamSpec("depth", .int, help: "Levels of children (1-64)")], timeout: 30),
            gcmd("screenshot", "Render a layer (default: the current page) to a PNG file; returns {path,width,height}", [node, out], timeout: 60),
            gcmd("export", "Export code (html|css|react, of --node or the page's top layers) or the whole file (figcraft); returns {path}",
                 [ParamSpec("format", .string, required: true, help: "html|css|react|figcraft"), node, out], timeout: 60),
            gcmd("help", "figcraft command ids and their parameters [{id,help}]",
                 [ParamSpec("query", .rest, positional: true, help: "Keep commands whose id or docs contain this text")], timeout: 30, panelFree: true),
            gcmd("link", "The panel file's edit link (the app only)", timeout: 30, exposedToMCP: false),
            gcmd("prefer", "The workspace's design-first preference (ask|always|never) for UI work; with a value sets it (Shepherd or the app) (ignores --panel); returns {designFirst}",
                 [ParamSpec("value", .string, positional: true, help: "ask|always|never (omit to read)")], timeout: 10, panelFree: true),
            gcmd("system.list", "Design systems [{name,version,active}] (ignores --panel)", timeout: 10, panelFree: true),
            gcmd("system.create", "Create a design system: a design file of that name seeded with starter tokens, a text style and a component (or a copy of --from), published as version 1 (ignores --panel); returns {name,version}",
                 [ParamSpec("name", .string, positional: true, required: true, help: "Name (1-80 of A-Z a-z 0-9 space . _ -)"),
                  ParamSpec("from", .string, help: "Design system to copy"), reason], timeout: 120, panelFree: true),
            gcmd("system.publish", "Publish the design system's file as its next version (needs a leash to a Design panel of it; ignores --panel); returns {name,version}",
                 [ParamSpec("name", .string, positional: true, required: true, help: "Design system"),
                  ParamSpec("force", .flag, help: "Publish even though the system was reverted and its file still shows newer content"),
                  reason], timeout: 120),
            gcmd("system.history", "The design system's events (created, published...), oldest first (ignores --panel)",
                 [ParamSpec("name", .string, positional: true, required: true, help: "Design system")], timeout: 10, panelFree: true),
            gcmd("system.use", "Make a design system the active one of the workspace (or of --paddock) and swap it into that scope's design files (workspace: the app or a Shepherd on the pasture; paddock: its creator Shepherd; ignores --panel); returns {scope,system,files}",
                 [ParamSpec("name", .string, positional: true, help: "Design system"),
                  ParamSpec("paddock", .string, help: "Paddock (default: the workspace, which pasture and paddocks without their own follow)"),
                  ParamSpec("none", .flag, help: "Clear the active design system instead (bindings stay)"), reason], timeout: 120, panelFree: true),
            gcmd("system.undo", "Make the scope's previous active design system active again and swap it back (ignores --panel); returns {scope,system,files}",
                 [ParamSpec("paddock", .string, help: "Paddock (default: the workspace)"), reason], timeout: 120, panelFree: true),
            gcmd("system.revert", "Publish an earlier version's snapshot as the design system's next version, taken by the files using it (needs a leash to a Design panel of it; ignores --panel); returns {name,version}",
                 [ParamSpec("name", .string, positional: true, required: true, help: "Design system"),
                  ParamSpec("to", .int, required: true, help: "Version to go back to"), reason], timeout: 120),
            gcmd("system.tokens", "The active design system's published tokens: collections (with modes), variables, styles and components of the panel file's library",
                 timeout: 30),
            gcmd("system.bind", "Bind layers to a variable of the active design system (as variable.bind)",
                 [ParamSpec("variable", .string, required: true, help: "Variable name (design.system.tokens)"),
                  ParamSpec("field", .string, required: true, help: "fill, stroke, cornerRadius, fontSize, paddingLeft..."), ids], timeout: 60),
            gcmd("system.style", "Apply a style of the active design system to layers",
                 [ParamSpec("style", .string, required: true, help: "Style name"), ids,
                  ParamSpec("target", .string, help: "fill|stroke|text|effect")], timeout: 60),
            gcmd("system.place", "Place an instance of a component of the active design system; returns its id",
                 [ParamSpec("component", .string, required: true, help: "Component name"),
                  ParamSpec("x", .string, help: "Page x (default: the view's centre)"), ParamSpec("y", .string, help: "Page y")], timeout: 60),
            gcmd("system.mode", "Set a mode (e.g. Light, Dark) of the active design system's variables on frames (default: the page)",
                 [ParamSpec("mode", .string, required: true, help: "Mode name"),
                  ParamSpec("ids", .string, help: "Frame ids, comma-separated"),
                  ParamSpec("collection", .string, help: "Variable collection (default Tokens)")], timeout: 60),
        ],
        events: ["design.changed", "designsystem.changed"],
        runsInDaemon: true)
}

extension PluginRegistry {
    private static func acmd(_ n: String, _ summary: String, _ params: [ParamSpec] = [], timeout: Double,
                             exposedToMCP: Bool = true) -> CommandSpec {
        // every artifact.* ignores --panel and checks no leash
        CommandSpec(name: "artifact.\(n)", summary: summary, params: params, timeoutSeconds: timeout, exposedToMCP: exposedToMCP, panelFree: true)
    }
    private static let artifactId = ParamSpec("id", .string, positional: true, required: true, help: "Artifact id (as artifact.list shows it)")

    /// Pages Collie keeps: HTML exports of designs (`design.export --format html`) and pages agents hand in; the daemon
    /// runs the commands (named `artifact.*`, the plugin is `artifacts`). Re-export and remove are the app's.
    static let artifacts = PluginSpec(
        id: "artifacts", title: "Artifacts",
        placements: [.dockRight, .dockLeft, .dockBottom], defaultPlacement: .dockRight,
        commands: [
            acmd("list", "Artifacts, newest first [{id,kind,title,file,node,by,at,version,url,path,source,thumbnail,status,importError,warnings}]; status: current|stale|missing|unknown (exports), pending|importing|failed (agent pages) (ignores --panel)",
                 timeout: 60),
            acmd("get", "One artifact, as artifact.list shows it without status (ignores --panel)", [artifactId], timeout: 10),
            acmd("add", "Keep an HTML page (.html/.htm, up to 8 MiB) as an artifact and start importing it as a design screen in the background (ignores --panel); returns {id, importing}",
                 [ParamSpec("path", .string, required: true, help: "The page (resolved against the current directory; absolute paths are accepted)"),
                  ParamSpec("root", .string, help: "A folder with the page's files (css, js, images, fonts), kept beside it: the page must be inside; up to 2000 files and 64 MiB, no links"),
                  ParamSpec("title", .string, help: "Title (default: the file name)"),
                  ParamSpec("width", .int, help: "Viewport width of the import in px (default 1440, 320-3840)")], timeout: 30),
            acmd("import", "Import an agent's page as a screen in a new design file (needs the Collie app); it becomes the page's export; returns {artifact, file, node, version, warnings} (ignores --panel)",
                 [artifactId, ParamSpec("width", .int, help: "Viewport width in px (default 1440, 320-3840)")], timeout: 180),
            acmd("reexport", "Export the artifact's design again as its next version (the app only)", [artifactId], timeout: 120, exposedToMCP: false),
            acmd("remove", "Set the artifact aside (the app only)", [artifactId], timeout: 10, exposedToMCP: false),
        ],
        events: ["artifact.exported", "artifact.added", "artifact.imported"],
        runsInDaemon: true)
}

extension PluginRegistry {
    /// The Work panel: works, approvals and the chat. No agent commands (agents use `collie work ...`); the app view talks
    /// to `work.*` directly. One per workspace (the app focuses an open one instead of opening another).
    static let work = PluginSpec(
        id: "work", title: "Trabalho",
        placements: [.dockRight, .dockLeft, .dockBottom], defaultPlacement: .dockRight,
        commands: [], events: ["work.changed", "work.chat", "work.approval"])
}
