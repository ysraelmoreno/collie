# Plan 2R — External Plug-ins, Phase 1: Web-UI Plug-ins

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The user installs a plug-in folder (manifest + web UI); its panel opens like a built-in (palette, `collie panel open <id>`, Shepherds, herds) and its commands reach agents through the leash (CLI, MCP) — with no helper process, no network and no project access yet.

**Architecture:** Plug-ins become data. `PluginRegistry.all` turns from a `static let` into built-ins + an external list held in a process-wide lock (`Synchronization.Mutex`), filled differently per process: the daemon loads installed manifests from `<root>/plugins/`; the app gets them in the snapshot and a `pluginsChanged` event; the `collie` CLI and `collie mcp` (sandboxed, can't read the root) ask the daemon (`plugin.specs`). `Commands.all` becomes computed over it, so CLI parsing, help, MCP tools, leash checks and routing work unchanged. One generic `WebPluginPanel` (a `PluginPanelView`) hosts any external UI on `collie-plugin://<id>/…` with all network blocked and a small `window.collie` bridge; commands go daemon → app (`ui.host`, as browser) → page.

**Tech Stack:** Swift 6.2 (`Synchronization`, `CryptoKit`), WebKit (`WKURLSchemeHandler`, `WKContentRuleList`, `WKScriptMessageHandlerWithReply`, `callAsyncJavaScript`), SwiftUI (Preferences).

**Spec:** `docs/superpowers/specs/2026-10-25-external-plugins-design.md` (phase 1) and its decisions: plug-ins see command args only; Shepherds may open external panels; install user-only; free and paid third-party plug-ins in scope later (phase 4).

## Global Constraints

- Phase 1 accepts only: `apiVersion: 1`, a `ui`, commands with `runs: "ui"`, `permissions` absent or empty. A `helper`, `runs: "helper"` or any permission → install refused with "precisa de um Collie mais novo (helpers/permissões chegam na fase 2/3)".
- Manifest id `^[a-z][a-z0-9-]{1,31}$`; never a built-in plug-in id nor a core command prefix (computed from `Commands.core` names: `panel`, `paddock`, `memory`, `work`, `lot`, `access`, `herd`, `plugin`, `admin`, `ui`, …). Command names `^[a-z][a-z0-9-]{0,31}$`, ≤ 64 commands, param kinds `string|int|flag|rest`, timeout 1–300 s (default 30). Folder ≤ 64 MiB, ≤ 5 000 files, no symlinks, no file outside the folder.
- Install, uninstall, enable, disable: admin only (app or `collie plugin …` outside a terminal; refused from `COLLIE_TERMINAL_ID`, as `admin.*`). `plugin.specs` and `plugin.list` are readable by terminals (names, versions, commands — no paths).
- Installed copy at `<root>/plugins/<id>/<version>/`, files 0444 / dirs 0555; `<root>/plugins/installed.json` (0600) holds `{id, version, sha256, enabled, installedAt}`. The daemon re-hashes at load; mismatch → that plug-in disabled with "conteúdo alterado desde a instalação; instale de novo".
- A bad or changed plug-in never breaks the workspace: it is skipped with its error shown in Preferences; its panels show a placeholder and keep their state.
- The page sees only command args (user decision 1): never the agent's text, terminal ids, tokens, paths of the root, other panels.
- Page network: `WKContentRuleList` blocks `http(s)`, `ws(s)`, `file`, and any scheme but `collie-plugin`; `websiteDataStore = .nonPersistent()`. The scheme handler serves only `<installed>/ui/**`, resolved, no `..`, correct MIME by extension.
- Page results: JSON, ≤ 1 MiB; `files.output` ≤ 16 MiB, extensions `png|svg|json|txt|md|csv|html`.
- External commands that set `outputFile: true` in the manifest join the 2O hand-over: `Commands.outputFile` becomes `CommandSpec.outputFile: Bool` (built-ins set it for the four existing names); the router checks the flag.
- Orientation (`CollieOrientation`, ≤ 1300 chars) lists built-ins only; one fixed suffix line for Shepherds when external plug-ins exist: `- More panels: collie plugin list`.
- UI copy pt-BR; code, manifest keys, API docs English.

## Review Focus

1. Uninstall while a panel of it is open and an agent call is in flight: the call fails `unavailable` ("plug-in removido"), the node shows the placeholder, MCP clients get `tools/list_changed`, nothing crashes.
2. Two versions: install 0.2 over 0.1 → open panels reload with 0.2, old folder removed after the swap; a failed install leaves 0.1 working.
3. Hostile page: `fetch("https://x")`, `<img src=http://…>`, `location = "file:///etc/passwd"`, `window.open`, a 50 MiB `files.output`, a result of 10 MiB, a command handler that never resolves (timeout) → all refused/timed out, app responsive.
4. A sandboxed agent's `collie <id> <cmd> --help` and its MCP tool list include the plug-in only when leashed to one of its panels (same reach rule as built-ins) and update within the MCP poll after install.
5. Daemon restart with a plug-in whose folder was edited by hand → disabled with the reason; everything else loads.

---

### Task 1: Manifest, install store, admin commands

**Files:**
- Create: `Sources/CollieCore/PluginManifest.swift` (decode + validate, pure)
- Create: `Sources/CollieDaemonKit/Plugins/PluginStore.swift` (install/uninstall/enable/list, tree hash, load-time verify)
- Create: `Sources/CollieDaemonKit/PluginAdminCommands.swift`; modify `Sources/CollieProtocol/Commands.swift` (`plugin.install --path`, `plugin.uninstall <id>`, `plugin.enable|disable <id>`, `plugin.list`, `plugin.specs`), `Sources/CollieDaemonKit/CommandRouter.swift` (route; admin checks)
- Create: `Examples/plugins/notas/` (sample + test fixture: `collie-plugin.json`, `ui/index.html`, `ui/app.js`, `LICENSE` MIT) — commands `add <text…>`, `list`, `export --format md` (`outputFile: true`)
- Test: `Tests/CollieCoreTests/PluginManifestTests.swift`, `Tests/CollieDaemonKitTests/PluginStoreTests.swift`

**Interfaces:**
- Produces: `struct PluginManifest: Codable, Sendable { apiVersion, id, name, version, author, license, placements, defaultPlacement, ui, commands: [Command], events, stateKeys, permissions }`; `PluginManifest.load(folder: URL) throws(ProtocolError) -> PluginManifest`; `func pluginSpec() -> PluginSpec` (commands named `<id>.<name>`, `runsInDaemon: false`, `source: .external(version:)`).
- Produces: `actor PluginStore { func install(from: URL) async throws(ProtocolError) -> InstalledPlugin; func uninstall(_ id: String) …; func setEnabled(_ id: String, _ on: Bool) …; func loaded() -> [(PluginManifest, InstalledPlugin)]; func folder(of id: String) -> URL? }`; `struct InstalledPlugin: Codable { id, version, sha256, enabled, installedAt, error: String? }`.

- [ ] **Step 1: Tests** (manifest): `decodesNotasExample`; `refusesBadId` (`Browser`, `x`, `panel`, `design`, `memory`); `refusesHelperInPhase1`; `refusesPermissionsInPhase1`; `refusesBadCommandName`; `refusesTimeoutOutOfRange`; `refusesTooManyCommands`; `specNamesPrefixed` (`notas.add`); `unknownKeysIgnored` (forward compatible).
- [ ] **Step 2: Tests** (store): `installCopiesReadOnlyAndHashes`; `installRefusesSymlink`, `installRefusesOver64MiB`, `installRefusesOutsideFile`; `reinstallNewVersionSwapsAtomically` and `failedInstallKeepsOld` (Review Focus 2); `loadDisablesChangedFolder` (Review Focus 5); `uninstallRemovesFolderAndEntry`; `adminOnly` (`plugin.install` with a terminal token → `unauthorized`); `specsReadableByTerminal` (no filesystem paths in the reply).
- [ ] **Step 3:** Run `swift test --filter "PluginManifestTests|PluginStoreTests"` → FAIL; implement; → PASS.
- [ ] **Step 4: Commit** `feat(plugins): manifest, install store and admin commands`.

### Task 2: Registry at runtime (daemon, app, CLI, MCP)

**Files:**
- Modify: `Sources/CollieProtocol/Plugins.swift` (`PluginRegistry.all` = `builtIn + external`, `static func setExternal(_ specs: [PluginSpec])` behind a `Mutex`; `PluginSpec.source`), `Sources/CollieProtocol/Commands.swift` (`all` computed; `CommandSpec.outputFile`; `outputFile` set → flag), `Sources/CollieDaemonKit/CommandRouter.swift` (2O check reads the flag)
- Modify: `Sources/CollieDaemonKit/Daemon.swift` (load at start, `setExternal`, emit `pluginsChanged` on any store change), `WorkspaceEvent` (`.pluginsChanged([PluginSpecDTO])`), snapshot (`plugins`)
- Modify: `Sources/CollieClient/DaemonClient.swift` (snapshot + event → `setExternal`)
- Modify: `Sources/collie/CLI.swift` (unknown command → one `plugin.specs` fetch → `setExternal` → retry parse), `Sources/collie/MCPServer.swift` (fetch at `initialize`; the existing poll also compares a catalog version from `plugin.specs` and sends `list_changed`)
- Modify: `Sources/CollieCore/Herd.swift` (external plug-in allowed with its manifest `stateKeys`), `Sources/CollieDaemonKit/CollieOrientation.swift` (built-ins only + suffix line)
- Test: `Tests/CollieProtocolTests/PluginRegistryTests.swift`, MCP server test, CLI test, `CollieOrientationTests`

**Interfaces:**
- Consumes: Task 1 `PluginManifest.pluginSpec()`, `PluginStore.loaded()`.
- Produces: `PluginSpecDTO: Codable` (the wire form of a `PluginSpec`), `PluginRegistry.setExternal(_:)`, `PluginRegistry.catalogVersion: Int`.

- [ ] **Step 1: Tests** `externalCommandsInCommandsAll`; `removingExternalDropsCommands`; `builtInsUnchanged` (the seven, same order, same specs); `outputFileFlagForBuiltIns` (the four names); `cliResolvesExternalAfterFetch`; `mcpListsExternalOnlyWhenReached` + `mcpListChangedAfterInstall` (Review Focus 4, poll shortened via `COLLIE_MCP_POLL_MS`); `herdAcceptsExternalWithStateKeys`; `orientationListsBuiltInsOnly` (worst case still ≤ 1300).
- [ ] **Step 2:** Implement; `swift test` → PASS (full suite: the registry change touches every command path).
- [ ] **Step 3: Commit** `feat(plugins): external plug-ins in the command registry`.

### Task 3: `WebPluginPanel` and the page bridge

**Files:**
- Create: `Sources/ColliePlugins/WebPluginPanel.swift` (view, scheme handler, rule list, bridge, state file, output files), `Sources/ColliePlugins/WebPluginBridge.js.swift` (the injected `window.collie` script as a string)
- Modify: `Sources/ColliePlugins/PluginPanelView.swift` (`PluginViews.make`: an external id with no registered type → `WebPluginPanel`; a missing plug-in → `MissingPluginPanel` placeholder), `Sources/CollieApp/CollieApp.swift` (pass the plug-ins root to the host context)
- Test: `Tests/CollieAppTests/WebPluginPanelTests.swift` (loads `Examples/plugins/notas` installed into a temp root)

**Interfaces:**
- Consumes: Task 2 registry; installed folder `<root>/plugins/<id>/<version>/ui/`.
- Produces — page API v1 (also documented in Task 4):
  - `collie.onCommand(async (name, args) => result)` — `name` without the id prefix; `args` exactly the command args minus `panel`.
  - `collie.emit(event, payload)` — only events declared in the manifest.
  - `collie.state.get(): Promise<object>`, `collie.state.set(obj)` — `<root>/plugin-data/<id>/<panelId>.json`, ≤ 256 KiB, deleted in `panelRemoved`.
  - `collie.files.output(name, base64): Promise<{path}>` — written under `<root>/screens/`, returned by the command so the 2O hand-over applies.
  - `collie.theme` — `{scheme: "light"|"dark", tokens: {…CSS var names → values}}` plus a `collie-theme` DOM event on change; tokens also set as CSS variables on `:root`.

- [ ] **Step 1: Tests** `notasAddThenList` (command through `handle` → page → result); `commandTimeout` (handler never resolves → `timeout` after the spec's seconds); `resultOver1MiBRefused`; `networkBlocked` (`fetch`, `img`, `location=file:` all fail — Review Focus 3); `schemeRefusesTraversal` (`collie-plugin://notas/../../installed.json` → 404); `undeclaredEventRefused`; `stateRoundTripAndDeletedWithPanel`; `outputFileReturnsPathUnderScreens`; `missingPluginShowsPlaceholder`; `uninstallDuringCallFailsUnavailable` (Review Focus 1).
- [ ] **Step 2:** Implement; tests PASS.
- [ ] **Step 3: Commit** `feat(plugins): web panel host and page API v1`.

### Task 4: Preferences, docs, end to end

**Files:**
- Modify: `Sources/CollieApp/PreferencesView.swift` (tab "Plug-ins": list with name, version, author, license, commands count, state/error; **Instalar…** (`NSOpenPanel`, folders only) → confirmation sheet listing commands; **Remover** (confirm); enable toggle), `Sources/CollieClient/DaemonClient.swift` (plugin.* calls)
- Create: `docs/plugins/api-v1.md` (manifest reference, page API, limits, what phase 2/3 add), `README.md` (section "Plug-ins externos", one paragraph + link)
- Modify: `docs/superpowers/specs/2026-10-25-external-plugins-design.md` (phase 1 shipped; Diagram port moves to phase 3, since it needs project read/write)

- [ ] **Step 1:** Preferences tab; disabled while disconnected; errors shown verbatim from the daemon.
- [ ] **Step 2: Manual end to end:** install `Examples/plugins/notas` from Preferences → open "Notas" from the palette → Shepherd: `collie panel open notas` and leash it to a sandboxed Claude → the agent runs `collie notas add "comprar café"`, `collie notas export --format md --out notas.md` and reads the file → uninstall with the panel open (Review Focus 1) → reinstall a bumped version (Review Focus 2).
- [ ] **Step 3:** `swift test` → PASS. Commit `feat(plugins): Preferences tab, API docs, sample plug-in`.
