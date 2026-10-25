# Collie plug-ins: API v1 (phase 1, web UI)

A plug-in adds a panel and agent commands to Collie without rebuilding it. Phase 1 plug-ins are **web UI only**:

- no helper process
- no network
- no access to the project

The page runs in a locked web view and talks to Collie only through `window.collie`.

Example: [`Examples/plugins/notas`](../../Examples/plugins/notas).

## Layout

```
collie-plugin.json   manifest (below)
ui/index.html        the page (any path under ui/; .html)
ui/…                 its scripts, styles, images, fonts
LICENSE
```

**Install** from Preferências → Plug-ins → Instalar…, or with `collie plugin install --path <folder>` run outside a Collie terminal. Installing is the user's alone: agents can't install, enable, disable or remove plug-ins.

**What the install does:**
- It copies the folder to `<root>/plugins/<id>/<version>/` and makes it read only: files 0444, directories 0555.
- It pins the folder's SHA-256 in `installed.json`.
- The daemon hashes the folder again at every start. A changed folder is not loaded, and shows "conteúdo alterado desde a instalação; instale de novo".

**What the folder can't contain:**
- symbolic or hard links
- special files
- more than 5 000 entries
- more than 64 MiB in total

Installing an id that is already installed replaces it only when asked to. Preferências asks first, and the confirmation shows the old and new author and version. The CLI refuses unless you pass `--replace`: `collie plugin install --path <folder> --replace`.

Preferências installs exactly the id and version it showed: if the folder changes between the confirmation and the copy, the install is refused.

## Manifest (`collie-plugin.json`)

```json
{
  "apiVersion": 1,
  "id": "notas",
  "name": "Notas",
  "version": "0.1.0",
  "author": "Collie",
  "license": "MIT",
  "placements": ["dock.right", "dock.left", "dock.bottom", "canvas"],
  "defaultPlacement": "dock.right",
  "ui": "ui/index.html",
  "commands": [
    { "name": "add", "summary": "Add a note", "runs": "ui",
      "params": [{ "name": "text", "type": "rest", "required": true, "positional": true, "help": "Note text" }] },
    { "name": "export", "summary": "Export the notes", "runs": "ui", "outputFile": true, "timeout": 30,
      "params": [{ "name": "format", "type": "string", "required": true, "help": "md" }] }
  ],
  "events": ["notas.changed"],
  "stateKeys": []
}
```

| Key | Rule |
|---|---|
| `apiVersion` | `1`. A higher one gets "precisa de um Collie mais novo". |
| `id` | Matches `[a-z][a-z0-9-]{1,31}`. It can't be a built-in plug-in id (`browser`, `design`, `diagram`, …) or the first word of a Collie command (`panel`, `plugin`, `admin`, `artifact`, `list`, …). It names the folder and the commands (`collie notas add`). |
| `name` | 1–64 characters, no control characters. |
| `version` | Matches `[0-9][0-9A-Za-z.+-]{0,31}`. |
| `author`, `license` | Optional. At most 128 and 64 characters. |
| `placements` | One or more of `canvas`, `dock.left`, `dock.right`, `dock.bottom`. `defaultPlacement` must be one of them. |
| `ui` | `ui/…/<file>.html`. Each component is a plain name; no `..`, no hidden dot names. |
| `commands` | At most 64. Each command has: <ul><li>`name`: matches `[a-z][a-z0-9-]{0,31}`, unique</li><li>`summary`: 1–2000 characters</li><li>`runs`: `"ui"`</li><li>`timeout`: 1–300 s, default 30</li><li>`outputFile`: default false</li><li>`params`</li></ul> |
| `params[]` | `name` matches `[a-z][a-z0-9-]{0,31}`, and `panel` is reserved. `type` is `string`, `int`, `flag` or `rest`. A `rest` param must be the last positional. A `flag` is neither positional nor required. `help` is at most 500 characters. |
| `outputFile` | The result's `path` is a file that Collie hands to the caller. `--out` is added when not declared; a declared `out` must be a non-positional string. |
| `events` | At most 64, each `<id>.<name>`. |
| `stateKeys` | Panel state keys a herd may save. |
| `helper`, `permissions` | Phase 2 and 3. Any value is refused with "precisa de um Collie mais novo (helpers/permissões chegam na fase 2/3)". The exceptions are an empty `network` list and `"project": "none"`. |

Unknown keys are ignored, so a newer manifest still loads.

**How agents see the commands:**
- They are `<id>.<name>`: `collie notas add "comprar café"`, or MCP `notas_add`.
- An agent reaches them only when it is leashed to a panel of the plug-in, the same rule as for built-in panels.
- MCP descriptions and param help are prefixed `[plug-in <id>]` and cut at 200 characters.
- The agent orientation never names external plug-ins. A Shepherd sees one line: `collie plugin list`.

## The page

The page is served from `collie-plugin://<id>/…`. Only files under `ui/` are reachable.

**Network:**
- Every network load is blocked: `http(s)`, `ws(s)`, `file`, any other scheme, and WebRTC.
- `fetch`, images, WebSockets, `window.open` and navigation away from the plug-in all fail.
- Camera and microphone are denied.
- Storage is not persistent. Use `collie.state` instead.

The page sees only the arguments of each command. It never sees the agent's request, terminal ids, tokens, or paths of the Collie root.

### `window.collie`

| Call | What it does |
|---|---|
| `collie.apiVersion` | `1` |
| `collie.onCommand(async (name, args) => result)` | Handles agent commands. `name` comes without the id (`"add"`); `args` holds the command's arguments (no `panel`). The result must be JSON, at most 1 MiB. A throw comes back to the agent as the error, cut to one line of 500 characters. A command that doesn't answer within its `timeout` fails with `timeout`. |
| `collie.emit(event, payload)` | Sends a plug-in event. The event must be declared in `events`, otherwise the promise rejects. The payload must be JSON, at most 64 KiB. |
| `collie.state.get()` / `collie.state.set(obj)` | The panel's own state: a JSON object of at most 256 KiB. It is kept across restarts and plug-in updates, and deleted when the panel is closed. |
| `collie.files.output(name, base64)` | Writes an output file, at most 16 MiB. `name` matches `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` with extension png, svg, json, txt, md, csv or html. The call resolves to `{path}`, an opaque handle; return it (or an object with that `path`) from an `outputFile` command. Collie writes the file under `<root>/plugins-out/<id>/` and gives the agent its own copy (`--out` works too). An `outputFile` result whose `path` didn't come from `files.output` is refused. Each plug-in may write at most 64 MiB of output files per day (all its panels together), and its newest 200 files are kept. |
| `collie.theme` | `{scheme: "light" \| "dark", tokens: {"--collie-text": "#…", …}}`. The tokens are also set as CSS variables on `:root`. A `collie-theme` event fires on `window` when the theme changes. |

### Lifecycle

- **Updating:** installing a new version reloads open panels with it.
- **Removing or disabling:** a command in flight fails with `unavailable` ("plug-in removido"). Open panels show "Plug-in <id> não está instalado" and keep their state.
- **Crash:** if the page's process dies, it reloads, up to 3 times.

## Later phases

- **Phase 2: helpers.** A process the daemon starts, run under the terminals' sandbox. Commands with `runs: "helper"`.
- **Phase 3: permissions.** A network allow-list and project read or write, approved by the user at install. The Diagram panel's port to an external plug-in waits for this phase, because it needs project read and write.
- **Phase 4: distribution.** Signed `.collieplugin` packages from third-party developers.
