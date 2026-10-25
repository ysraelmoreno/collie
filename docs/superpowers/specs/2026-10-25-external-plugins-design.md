# External Plug-ins — Design

**Status:** agreed (2026-10-25; decisions at the end). Splits into one plan per phase. **Phase 1 shipped** (plan 2R Plugins; API reference: `docs/plugins/api-v1.md`).

## Why

Today every plug-in is compiled into Collie: `PluginRegistry.all` (`CollieProtocol/Plugins.swift`) lists seven `PluginSpec`s and the app registers their views (`PluginViews.register`, `CollieApp.swift:51`). Adding one (e.g. the Diagram panel, plan 2Q) means a Collie release. External plug-ins let the user — and later others — add panels and agent commands without rebuilding Collie, without weakening its rules: the leash is the only permission, nothing leaves the machine unasked, secrets never reach agents.

## What a plug-in is

A folder (or a `.collieplugin` zip of it):

```
collie-plugin.json      manifest
ui/                     web UI (index.html + assets), optional
bin/<helper>            helper executable, optional
LICENSE
```

Manifest (`apiVersion: 1`):

```json
{
  "apiVersion": 1,
  "id": "kanban",                       // [a-z][a-z0-9-]{1,31}; never a built-in id or a reserved word
  "name": "Kanban", "version": "0.3.0", "author": "…", "license": "MIT",
  "placements": ["canvas", "dock.right"], "defaultPlacement": "canvas",
  "ui": "ui/index.html",
  "helper": "bin/kanban-helper",        // optional
  "commands": [
    { "name": "add", "summary": "Add a card", "runs": "ui",
      "params": [{ "name": "title", "type": "string", "required": true, "positional": true }],
      "timeout": 30, "outputFile": false }
  ],
  "events": ["kanban.changed"],
  "permissions": {
    "network": [],                       // hosts the UI/helper may reach; empty = none
    "project": "none"                    // none | read | write  (the opening terminal's project)
  }
}
```

Commands are exposed as `<id>.<name>` exactly like built-ins: CLI help, MCP tools (`tools/list_changed` already exists), leash checks, `--panel`, herd state keys (declared in the manifest as `stateKeys`).

## Where code runs

| Part | Runs in | Isolation |
|---|---|---|
| UI | a `WKWebView` in the app, scheme `collie-plugin-<id>://` | non-persistent or per-panel data store; `WKContentRuleList` blocks every network load except `permissions.network` hosts; no file access beyond its own folder |
| Helper | a process the **daemon** starts on first use, JSON-RPC over stdio (same framing as MCP) | Seatbelt profile built with the 4S machinery: no home reads, its own data dir writable, project per `permissions.project`, network per `permissions.network`, no exec of `launchctl`/`open` |
| Commands `runs: "ui"` | daemon → app (`ui.host`, as browser) → page `collie.onCommand` | page only |
| Commands `runs: "helper"` | daemon → helper | helper sandbox |

Host API inside the page (`window.collie`, versioned with `apiVersion`): `onCommand(handler)`, `emit(event, payload)`, `state.get/set` (panel state, persisted), `files.output(name, bytes)` (writes an output file the daemon hands over, plan 2O), `project.read/write(relPath)` (only if granted), `theme` (Collie tokens, light/dark). Nothing else of the daemon: no `paddock.*`, `memory.*`, `work.*`, no admin calls, no other panels.

The helper gets the same host API as JSON-RPC methods the daemon serves on its stdio.

## Install, trust, update

- Admin only: the app (Preferências → Plug-ins → Instalar…) or `collie plugin install <path>` outside a terminal. Agents can never install, enable or update a plug-in (`plugin.*` admin-only, refused from `COLLIE_TERMINAL_ID`).
- Install screen shows name, author, license, commands, and permissions in plain pt-BR ("Pode acessar: api.trello.com", "Pode escrever no projeto"); nothing granted silently.
- Stored at `<root>/plugins/<id>/<version>/`, read-only after install; the daemon pins the folder's SHA-256 and refuses to load a changed folder (re-install).
- Helper binaries must be code-signed (any identity, hardened runtime); unsigned → refused, with the reason.
- Update = install of a new version; if permissions grew, the user approves again; otherwise one click.
- Disable/uninstall: open panels of it show a placeholder "Plug-in <name> não está instalado" (like an unknown placement falls back today) and keep their state; commands disappear from MCP (`list_changed`).

## Lifecycle and failure

- Load at daemon start and on install; a bad manifest disables only that plug-in (error in Preferências), never the workspace.
- Helper: started lazily, stopped when no panel of the plug-in is open for 5 min; crash → commands fail with `unavailable` and one restart attempt; time and memory caps per call (manifest timeout, max 300 s).
- Versioning: Collie supports `apiVersion` N and N-1; a plug-in asking for a newer one is shown as "precisa de um Collie mais novo".

## How built-ins relate

`PluginSpec` gains a source (`builtIn` | `external(manifest)`); `PluginRegistry.all` becomes built-ins + loaded manifests (an actor-held list, since it changes at runtime — today it's a `static let`). `PluginPanelView` stays the native protocol; external ones use one generic `WebPluginPanel` that implements it over the page bridge. The Diagram panel (plan 2Q) is built in now for speed; porting it to an external plug-in is the first proof the API is enough.

## Phases

1. **UI-only plug-ins** (no helper, no network, `project: none`): manifest, install/uninstall, `WebPluginPanel`, page bridge, registry at runtime, MCP list change. Proof: the "Notas" plug-in (`Examples/plugins/notas`). **Shipped.** As built: scheme `collie-plugin://<id>/` (one scheme, the id as host); output files written by the app host into `<root>/plugins-out/<id>/`, the page gets opaque handles.
2. **Helpers** under Seatbelt, JSON-RPC, lifecycle.
3. **Permissions**: network allow-list and project read/write, with the install screen. The Diagram port moves here: it needs project read/write (its `.drawio` lives in the project).
4. **Distribution**: `.collieplugin` packaging, signature of the package (developer key), optional catalog. Out of scope until someone asks.

## Decisions (user, 2026-10-25)

1. A plug-in sees only the command args, never the agent's request text.
2. A Shepherd may open an external plug-in's panel, like a built-in; installing stays user-only.
3. Both free and paid third-party plug-ins are in scope: phase 4 must support a signed package from a third-party developer and leave room for paid distribution (licence check owned by the plug-in, never by Collie's daemon calling out).
