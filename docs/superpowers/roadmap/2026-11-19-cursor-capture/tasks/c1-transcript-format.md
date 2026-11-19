# C1: TranscriptChunk reads a Cursor transcript

Design: `../design.md`. Read it first.

## Build

In `Sources/CollieDaemonKit/Memory/TranscriptChunk.swift`, `message(_:)` also accepts cursor-agent's line shape:

```json
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Wed Nov 18 2026</timestamp>\n<user_query>\nfaça X\n</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"feito"},{"type":"tool_use","name":"Shell","input":{}}]}}
{"type":"turn_ended","status":"success"}
```

- A Cursor line has `role` at the top level and no top-level `type`; `message` has no `role`. Claude's lines keep
  working exactly as today (same checks: `isMeta`, `isSidechain`, `message.role == type`).
- Only `text` items are kept. `tool_use` and anything else is dropped. A line with no `role` (`turn_ended`) is skipped.
- `clean(_:)` also removes each `<timestamp>…</timestamp>` block and unwraps `<user_query>…</user_query>` (the inner
  text stays, the tags go).
- No new type, no new file in `Sources`. The doc comment of the enum says both formats.

## Tests

Add to `Tests/CollieDaemonKitTests/TranscriptChunkTests.swift`, with these exact names:

- `cursorUserAndAssistantText`: the three lines above → `"Usuário: faça X\n\nAgente: feito"`, `userMessages == 1`.
- `cursorToolUseOnlyLineIsSkipped`: an assistant line with only `tool_use` adds nothing.
- `cursorTurnEndedIsSkipped`: the `turn_ended` line adds nothing and `end` is still the byte after it.
- `claudeLineStillNeedsMatchingRole`: a Claude line whose `message.role` differs from `type` is still dropped.

## Done when

`swift test --disable-sandbox --filter TranscriptChunkTests` passes, the four tests above included, and no existing
test of that file was removed or weakened. Commit with a `feat(memory):` message.
