# Terminal em chat (+ Generative UI) — Design

Prévia: `docs/pages/terminal-chat/index.html` (collie-designer). Related: `2026-11-08-paddock-apps-design.md`.

## Why

A Claude terminal shows the raw TUI: redraws, spinners, dialogs drawn in box characters. Reading what an agent did,
answering its questions and seeing structured results (pods, diffs, tasks) is harder than it needs to be. A chat
body renders the same session as messages, collapsible tool calls, clickable cards, and blocks the agent asks for
(Generative UI). The real terminal stays one click away.

## Style: Terminal | Chat

- **Preferências → Aparência → "Estilo do terminal"**: Terminal (default) | Chat. `@AppStorage` like the other
  appearance keys; the default for every terminal.
- **Header toggle** Chat ⇄ Terminal per terminal: overrides the preference for that terminal, saved on its record
  (`TerminalRecord.style: nil|terminal|chat`, nil = follow the preference).
- Chat applies only to presets with a transcript (Claude). Shell, Cursor, Codex: Terminal only, toggle hidden.
- Small node (< 420 pt wide): text only; each block collapsed to one line with "abrir".

## Data: transcript + hooks, not the screen

- The daemon already gets each Claude terminal's `transcript_path` from its hooks and vets it
  (`TranscriptChunk.allowed`). New: it keeps the path on the terminal (in memory) and serves
  `terminal.chat <name> [--since <offset>]` → `{entries: [...], end}`. Entries: user text, assistant text,
  tool_use (name, input summary; Edit/Write with the diff), tool_result (status, ≤ 8 KiB preview), and `ui` blocks.
  Content is untrusted data, scrubbed of secrets like `TranscriptChunk`.
- Event `terminal.chatChanged {id, end}` on UserPromptSubmit / PostToolUse / Stop hooks; the app fetches `--since`.
- The screen stays the source for dialogs: `AttentionDetector` (permission, AskUserQuestion, trust folder).

## Input

- The composer sends through the existing prompt delivery (text, then Enter, confirmed by UserPromptSubmit).
- **While a dialog is up, typed text is queued** (shown as "na fila"), sent when the dialog closes. Never typed into
  the dialog (pitfall: injected text becomes the dialog's answer).
- Dialog cards: permission (Permitir / nesta sessão / Negar) and questions answered as **keys/options** through the
  path chat approval already uses; never as text. Trust-folder stays terminal-only (existing decision).

## Generative UI (v1: fence only)

The agent writes a fenced block in its reply:

````
```collie-ui
{"kind": "table", "title": "Pods", "columns": ["nome","status"], "rows": [["api","Running"]]}
```
````

- Kinds v1: `table`, `diff`, `tasks`, `chart` (bar/line, ≤ 500 points), `form` (choices → sent back as a normal
  prompt, labelled as the user's choice), `status` (key/value). Unknown kind or bad JSON: shown as code.
- Native SwiftUI renderers; no HTML/JS from the agent in v1. Each block has "{ } JSON".
- "Anexar como painel": opens it as a panel **linked to the source** when the block names an app do cercado
  (`"source": {"app": "kube", "command": "pods"}`), refreshed through that app's command; otherwise a snapshot panel.
- Orientation text teaches agents the fence and the kinds (short).
- Later (not v1): MCP tool `ui.render` / `ui.update` to update a block in place.

## Slices

1. Preference + header toggle + `TerminalRecord.style`; `terminal.chat` + `chatChanged`; chat body with messages
   and collapsible tool calls; composer with the dialog queue; Terminal ⇄ Chat keeps the session.
2. Dialog cards (permission, AskUserQuestion) through the chat-approval path.
3. `collie-ui` fence: table, diff, tasks, status, form, chart; orientation text.
4. "Anexar como painel" (snapshot, then linked to an app do cercado once that ships).

## Decisions (owner, 2026-11-08)

1. Opt-in: Preferências sets the default style (Terminal | Chat); the header toggle overrides per terminal.
2. Composer during a dialog: queue, never type into it.
3. v1 blocks by fence only; the MCP tool later.
4. Attached panel: linked to its source (app do cercado); snapshot as fallback.
5. Node < 420 pt: text only, blocks collapsed.
6. Presets without a transcript: Terminal only.
