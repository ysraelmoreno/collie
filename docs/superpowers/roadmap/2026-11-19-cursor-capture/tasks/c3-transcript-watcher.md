# C3: the daemon notices a Cursor conversation moved

Design: `../design.md`. Read it first. Needs C2.

Cursor has no turn hook, so nothing tells the daemon a turn ended. The transcript file growing is the signal.

## Build

In `Sources/CollieDaemonKit/Memory/ConversationCapture.swift`:

- `DaemonConfig.cursorTranscriptPoll: Duration = .seconds(30)` (next to `conversationIdle` in `Daemon.swift`).
- `ConversationTriggers.watch: [UUID: Task<Void, Never>]`. `cursorSessionStarted` (C2) starts one watcher per
  terminal, cancelling the previous one.
- The watcher loop, every `cursorTranscriptPoll`:
  1. Ends when the terminal is no longer in the workspace.
  2. If only a session id is known, tries to find the file again (C2's lookup).
  3. `stat`s the transcript. When its size differs from the last size seen, it restarts the idle capture: the same
     timer `conversationTurnEnded` uses (`conversationIdle`, then `captureConversation(force: false)`), without
     `recordUsage`. Share the timer code; do not copy it.
- When a Cursor terminal's process ends or the terminal is removed: `captureConversationNow(tid)` once, then the
  watcher is cancelled. Find where the router already learns that a terminal ended and hook there.

ponytail: a 30 s `stat` per Cursor terminal, no FSEvents. Say so in a `ponytail:` comment with the upgrade path.

## Tests

Add to `Tests/CollieDaemonKitTests/ConversationCaptureTests.swift`, with these exact names, using a config with
`cursorTranscriptPoll` and `conversationIdle` of a few milliseconds:

- `cursorTranscriptGrowthCapturesAfterIdle`: registered Cursor transcript with 3 user messages, then appended → a
  `conversation` job is queued with no hook and no `memory.capture`.
- `cursorTranscriptUnchangedQueuesNothing`: no growth → no job.
- `cursorShortChunkWaits`: growth with fewer than 3 user messages → no job (as for Claude).
- `cursorTerminalEndCapturesNow`: the terminal ends with 1 new user message → a job is queued at once.

## Done when

`swift test --disable-sandbox --filter ConversationCaptureTests` passes, the four tests above included. Commit with a
`feat(memory):` message.
