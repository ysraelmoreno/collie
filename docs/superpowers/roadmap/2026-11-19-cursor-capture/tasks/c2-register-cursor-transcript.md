# C2: a Cursor sessionStart registers the terminal's transcript

Design: `../design.md`. Read it first. Needs C1.

## Build

1. `Sources/CollieProtocol/HookPayload.swift`: `sessionId(stdinJSON:)` returns the payload's `session_id` when it is a
   UUID string, else nil.
2. `Sources/collie/HookCommands.swift`, `cursor-session-start`: also sends `session` (that id) to
   `memory.hookContext`. `MemoryHookClient.output` gets the parameter; `Commands.swift` declares `--session`.
3. `Sources/CollieDaemonKit/Memory/ConversationCapture.swift`:
   - `cursorProjectsDir(_ me:)`: `CURSOR_DATA_DIR` from the terminal's environment (non-empty) + `/projects`, else
     `sandboxHomeDir/.cursor/projects`. Same shape as `claudeProjectsDir`.
   - `projectsDir(_ me:)`: Cursor's for a Cursor terminal (`Self.agentName(me) == "cursor"`), Claude's otherwise.
     `captureConversation` uses it. `conversationRun` already re-checks against the payload's `projects`.
   - `cursorSessionStarted(_ tid:, transcript: String?, session: String?)`: remembers the transcript in
     `conversations.transcripts[tid]`. With no `transcript`, and a `session`, the path is the one match of
     `<cursorProjects>/*/agent-transcripts/<session>/<session>.jsonl` if that file exists; else nothing is remembered
     yet and the session id is kept so C3 can look again. Never throws.
4. `Sources/CollieDaemonKit/MemoryCommands.swift`, `memory.hookContext`: for a Cursor caller, calls
   `cursorSessionStarted`. `memory.capture`'s error becomes `no conversation seen for '<name>' yet`.
5. `TranscriptChunk.allowed` is unchanged: a Cursor path outside Cursor's `projects`, a symlink or a non-`.jsonl` is
   refused with the existing log line.

No token usage is read for a Cursor transcript: `recordUsage` is not called for it.

## Tests

Add to `Tests/CollieDaemonKitTests/ConversationCaptureTests.swift` (reuse its helpers), with these exact names:

- `cursorSessionStartRegistersTranscript`: a Cursor terminal, `memory.hookContext` with a transcript under its Cursor
  `projects` dir → `memory.capture` queues one `conversation` job; running it with the fake curator call writes a
  record whose origin is `conversa (<terminal name>)` and a digest row `aprendido`.
- `cursorTranscriptOutsideProjectsIsRefused`: a `.jsonl` outside Cursor's `projects` dir → no job.
- `cursorSessionIdFindsTranscript`: no `transcript`, only `session`, the file at
  `<projects>/<any slug>/agent-transcripts/<session>/<session>.jsonl` → captured.
- `claudeTerminalStillUsesClaudeProjects`: a Claude terminal's transcript under `.claude/projects` is still captured.

And in `Tests/CollieProtocolTests/HookPayloadTests.swift`: `sessionIdOnlyWhenUUID`.

## Done when

`swift test --disable-sandbox --filter ConversationCaptureTests` and `--filter HookPayloadTests` pass, the tests above
included. Commit with a `feat(memory):` message.
