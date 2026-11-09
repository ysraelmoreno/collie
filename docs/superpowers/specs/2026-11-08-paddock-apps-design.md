# Apps do cercado (additive UI) — Design

## Why

The owner builds their own tools: e.g. a cluster viewer for DOKS/Kubernetes/Docker (their own "ArgoCD"). Such a
tool belongs to one paddock: the user works in its UI, and the paddock's agents should see what it shows, call its
actions and hear its events. Today that needs a browser panel (`panel open browser --url localhost:…`) plus a
separately configured MCP server, and nothing ties them together: who runs the service, events reaching the
agent's turn, what the user is looking at, the panel coming back with the paddock.

An **app do cercado** is a living product attached to a paddock, with two faces:

- **User**: a live panel on the canvas, in the paddock, reopened with it.
- **Agent**: the app's actions as tools, its events as notices, its current context (what the user selected).

"Additive": an agent can add an app to the paddock's workflow mid-conversation (write its manifest, attach its
panel); the user approves it once.

## Not a new system: external plug-ins, scoped to a paddock

External plug-ins (spec `2026-10-25-external-plugins-design.md`, phase 1 shipped) already have the manifest, the
page bridge (`window.collie`: `onCommand`, `emit`, `state`, `theme`), commands exposed as MCP tools to the
terminals that reach the panel, and `tools/list_changed`. An app is an external plug-in whose source is the
paddock instead of `<root>/plugins/`:

| | Installed plug-in | App do cercado |
|---|---|---|
| Source | `<root>/plugins/<id>/<version>/` | `<paddock>/.collie/apps/<id>/collie-plugin.json` |
| Trust | user installs (admin) | user approves in the paddock (card); an agent may write it, never approve it |
| Pin | folder SHA-256 at install | manifest (+ local `ui/` folder) SHA-256 at approval; a change asks again |
| Seen in | every paddock | that paddock only (panel, tools, events) |
| UI | `ui/…` file | `ui/…` file, **or** a loopback URL served by the app's own service |
| Commands | `runs: "ui"` | `ui`, **or** `runs: "http"`: the daemon calls the app's service |

Decision 1 of the plug-in spec ("agents can never install") holds: approval is the user's only.

## Manifest (`apiVersion: 2`, extends v1)

```json
{
  "apiVersion": 2,
  "id": "kube", "name": "Kube", "version": "0.1.0", "author": "…", "license": "private",
  "placements": ["canvas"], "defaultPlacement": "canvas",
  "ui": "http://127.0.0.1:4100/",                  // or "ui/index.html"
  "service": { "base": "http://127.0.0.1:4100",     // loopback only (127.0.0.1, ::1, localhost)
               "start": "npm run serve", "health": "/healthz" },   // start/health: slice 5
  "commands": [
    { "name": "pods", "summary": "List pods", "runs": "http",
      "http": { "method": "GET", "path": "/api/pods" },
      "params": [{ "name": "namespace", "type": "string", "required": false, "positional": true }], "timeout": 30 },
    { "name": "restart", "summary": "Restart a deployment", "runs": "http",
      "http": { "method": "POST", "path": "/api/restart" }, "confirm": true,
      "params": [{ "name": "deployment", "type": "string", "required": true, "positional": true }], "timeout": 60 }
  ],
  "events": ["kube.pod.crashed", "kube.deploy.failed"],
  "eventStream": "/api/events",                     // SSE: slice 2
  "stateKeys": ["namespace"]
}
```

`runs: "http"`: the daemon sends the params as JSON (query string for GET) to `service.base + http.path`, timeout
per command (≤ 300 s), body ≤ 1 MiB; the JSON reply is the tool's result. Never a redirect off the base, never a
host other than the declared loopback base.

`confirm: true`: the call raises a user card in the app ("Kube quer: restart api-gateway — Permitir / Negar")
before the daemon sends it, even when an agent calls it. For destructive actions.

## Agent side

- Tools: `<id>.<command>` (MCP `kube_pods`, CLI `collie kube.pods default`) for terminals that reach the app's
  panel, the existing plug-in rule. `collie app attach <id>` opens the panel in the caller's paddock and leashes it
  to the caller.
- Events (slice 2): the daemon subscribes to `eventStream` (SSE) and takes page `emit`s; an event declared in
  `events` reaches the leashed terminals as a notice (like an ask reply), rate-limited, body behind a reference
  (`collie app event <id>`), never typed as the user's words.
- Context (slice 3): `collie.context({…})` in the page (≤ 16 KiB JSON) is what the user is looking at; the agent
  reads it with `collie app context <id>`, and `collie app snapshot <id>` returns the rendered page (reuses
  `HTMLSnapshotter`).

Everything an app sends to an agent (results, events, context) is **data from the app**, labelled so; a pod log
line can never instruct the agent.

## User side

- The approval card shows name, service base, commands (the `confirm` ones marked), events, in plain pt-BR.
- The panel is a `WebPluginPanel`; a URL `ui` is loaded with a content rule list allowing only `service.base`
  (and the page's own data/blob). The bridge is injected only for that origin.
- Service down: the panel shows "Kube não está respondendo em 127.0.0.1:4100" with Tentar de novo; tools fail
  with `unavailable` and that text.
- The panel and its state persist with the paddock; landing or deleting the paddock removes its apps' approvals.

## Slices (each usable on its own)

1. **App + panel + http tools.** `apiVersion 2` (`ui` URL, `service.base`, `runs: "http"`, `confirm`), paddock
   discovery of `.collie/apps/*/collie-plugin.json`, approval card + pin (per paddock, on the workspace record),
   `collie app list|attach|approve` (approve: admin only), tools reach as today, confirm card.
2. **Events**: SSE subscription + page `emit` → notices to leashed terminals.
3. **Context and snapshot**: `collie.context`, `collie app context|snapshot`.
4. **Additive by the agent**: `collie app new <id>` scaffolds a manifest + `ui/index.html` in the paddock and raises
   the approval card; orientation text tells agents when to offer it.
5. **Service supervision**: `service.start` run by the daemon in the paddock (the terminal sandbox profile, network
   allowed), health check, restart with backoff, logs in `collie app logs <id>`.

## Decisions (owner, 2026-11-08)

1. Collie runs the app's service (slice 5 is in scope).
2. The `confirm` card has three answers: Permitir (this call), Permitir nesta sessão (that command of that app,
   until the terminal's session ends or the app's pin changes), Negar.
