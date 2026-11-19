# Learning from Cursor conversations

2026-11-19. Owner's request: a machine that runs only Cursor terminals shows no "aprendido" entries.

## Why nothing is learned today

`ConversationCapture` reads a Claude transcript named by Claude's hooks (`turn.completed`, session end, compaction).
A Cursor terminal fires only `sessionStart` (spike REPORT §8), so no trigger ever runs and `conversations.transcripts`
never holds a path for it. `collie memory capture` answers "no Claude conversation seen".

## What was measured (cursor-agent 2026.11.17, this Mac)

- cursor-agent writes a plain-text transcript for every interactive session:
  `<data>/projects/<cwd slug>/agent-transcripts/<session id>/<session id>.jsonl`, `<data>` = `CURSOR_DATA_DIR`, else
  `~/.cursor` (spike REPORT §3).
- It is append-only JSONL. Three line shapes:
  - `{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>…</timestamp>\n<user_query>\n…\n</user_query>"}]}}`
  - `{"role":"assistant","message":{"content":[{"type":"text","text":"…"},{"type":"tool_use",…}]}}`
  - `{"type":"turn_ended","status":"success"}`
- The `sessionStart` payload carries `transcript_path` and `session_id` (spike REPORT §8.2), and the
  `cursor-session-start` hook already forwards `transcript_path` to `memory.hookContext`.
- `~/.cursor/chats/<md5 of cwd>/<session>/store.db` (SQLite, blobs) holds the same conversation with tool results. Not
  used: the JSONL is simpler and already text only.

## Decision

The transcript file is the source (the owner's option B). The terminal screen (option A) is not read: it is TUI
repaint, and the file has the same text clean. Option A's idea survives as the trigger: with no turn hook, the daemon
notices by itself that the conversation moved.

1. **Format** (C1): `TranscriptChunk` reads Cursor's lines as well as Claude's.
2. **Registration** (C2): a Cursor `sessionStart` registers the terminal's transcript; the path is vetted against
   Cursor's own `projects` dir; `memory.capture`, work done and merge capture it like a Claude one.
3. **Trigger** (C3): one watcher per Cursor terminal looks at the transcript's size on an interval. Growth restarts the
   existing idle capture (`conversationIdle`, 10 min, ≥ 3 user messages). The terminal ending captures at once.

Unchanged: the curator job, the byte marks, the scrub, R19 (a feedback only with the user's quote, as a proposal), the
digest rows ("aprendido … da conversa de <terminal>"), a `limited` curator's records all proposals.

## Limits, on purpose

- Collie only reads under Cursor's `projects` dir. It writes nothing there.
- The text goes to the chosen curator provider, as a Claude conversation's does (the consent already covers
  "trechos das suas conversas").
- A Cursor session that started before the daemon did is not captured until its next `sessionStart`.
- No token usage is read from a Cursor transcript (it has none).
- Not verified live: that `transcript_path` is non-empty on a brand new session's `sessionStart`. C2 covers it with
  the `session_id` fallback.
