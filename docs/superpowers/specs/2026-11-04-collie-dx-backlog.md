# Collie DX backlog (2026-11-04)

Problems hit by the Shepherd, design, iOS dev and remote-api terminals in one session, plus recurring pitfalls
from project memory. Ordered by impact. Each item: what happened (evidence) → proposed improvement.

**Status (2026-11-05): all done** — 1 b3ebaa2, 2 179b2b6, 3 55cf613, 4 d46a92f, 5 87ec43a+41f7d2f, 6 3ed0e9b,
7 216ffce, 8 9f6fa3e+b5dc2e9, 9 649c776, 10 project memory only (no code, owner's call), 11 c929e26+c7a7ddf+948386e,
12 689d691, 13 5f0f520, 14 63493ec, 15 e12cc4b, 16 0203ad6, 17 f12ae1b, 18 bd83571.

## P0 — delegation day to day

1. **Ask came back empty** — fixed in `0d62d13` (`delivered` resumed any waiter with `""` after
   `confirmSubmit`; only injects should). 8/8 asks this session returned empty. Not live until the daemon
   is rebuilt and restarted (see 12).
   → Store how/when an ask ended in `AskInbox` (source hook/idle, deliveredAt, completedAt) and show it in
   `collie ask result`; it would have cut the diagnosis short.
2. **`collie check` unreadable** — returns the raw redraw stream with ANSI stripped (spinner frames,
   "Orchestrating… 9 12 ✻ 4…"). Telling whether an agent finished meant digging through it.
   → `check --screen`: the final rendered screen. Reuse the remote API's `terminal.screen` (slice 4).
3. **No reliable "agent finished" signal** — the Shepherd depended on each agent remembering
   `collie ask "Collie Main" --no-wait` at the end (and those replies came back empty, item 1).
   → `collie wait <name>` (blocks until the turn ends; timeout) and an automatic event/notice to the
   Shepherd when a leashed agent ends a turn, with the last message's summary.
4. **Replies arrive as pasted text in the Shepherd's input** — iOS dev's and remote-api's reports landed as
   `[Pasted text]` blocks; one sat unsent in the input (iOS dev noticed).
   → Long replies typed as a short reference ("Reply from X (ask id) — `collie ask result <id>`") with
   the body behind it; confirm submit like the prompt-delivery fix does.
5. **Can't reach an existing terminal** — "design" existed but wasn't leashed: `summon` said "already
   exists", `ask` said "No connection", `collie leash` needs both ends leashed to the caller, `collie list`
   didn't show it.
   → `list --all` shows the paddock's unreachable terminals with a hint; the Shepherd can request a leash
   (user card); errors say what to do.

## P1 — CLI and memory friction

6. **No per-command help** — `collie summon --help` → "unknown flag --help"; `collie memory save` revealed
   required fields one at a time (kind, then subject, then title); the design agent gave up saving.
   → `--help` per command, all missing required args in one error, usage examples.
7. **`artifact new` without a name creates `prototype-1`** — design agent made a stray Prévia and had to
   delete it. → Require a name, or print the created path loudly.
8. **Memory injection noisy and duplicated** — Android CA/mitm memories injected on iOS/pricing/Windows
   questions; duplicates in the index (axe stream-video ×3, restart-all ×2, empty "net-core … sem sinal"
   summaries); almost everything "não revisada".
   → Relevance threshold for injection; dedupe/consolidate; drop empty summaries ("Context compacted",
   "sem sinal"); a review flow.
9. **Stale pitfall** — "Resposta vazia de ask não indica que o worker terminou" says cause unknown; it is
   known now. → Mark superseded; a simple `memory supersede` in the CLI.

## P1 — sandbox and shared worktree

10. **Sandbox blocks legitimate tools** — Swift macros (`@Observable`) fail in the sandbox (iOS dev changed
    architecture to avoid it); tests with `sandboxHome` fail with `closed` inside an agent's sandbox
    (existing `SandboxGrantTests` too); nested `sandbox-exec` fails.
    → Allow the compiler's macro plugin process in the profile; an official way to run those tests outside
    the sandbox (daemon-side runner with an approval card); document which tests can't run inside.
11. **Agents in one worktree break each other's builds** — "input file … was modified during the build"
    while another agent edited `RemoteAddress.swift`; memory has a test build broken by another agent's WIP.
    → Orientation gives each agent its own `--scratch-path .build/<agent>`; warn when building with another
    agent's dirty files.
12. **A daemon fix doesn't reach the running Collie** — `0d62d13` is committed but the installed app/daemon
    run old code (memory: "Rebuild não atualiza processo").
    → A dev update flow (`collie admin dev-reload`?): build, swap binary, restart daemon keeping terminals.

## P2 — robustness

13. **A panel command can crash the whole app** — divide-by-zero in the full-page screenshot (fixed in
    `be9439c`). → Audit integer traps in panel command paths; `preview.screenshot` ensures the view has a
    size before capturing.
14. **Ask replies are memory-only** — `AskInbox` loses them on daemon restart (its own ponytail comment).
    → Persist, together with item 1.
15. **`summon --cwd` help vs behaviour** — help says "within your project", but a cwd outside
    (`~/Documents/codes/collie-ios`) worked and the agent can write there. → Decide the rule; align help and
    sandbox; show the folder-trust dialog on the canvas.

Outside Collie (record only): the rtk hook rewrites commands and auto mode asks to re-issue ("no verdict").

## Added during the session

16. **False "did not submit" on a busy Claude** — ask `231b0fa5` to iOS dev failed with "'iOS dev' did not
    submit the prompt" while the agent was mid-turn: Claude queued the prompt (its screen showed
    "ctrl+x ctrl+s to send now"), so no UserPromptSubmit came within `submitConfirm`, and a quiet moment
    made `confirmSubmit` give up. The prompt was not lost, only reported as failed (risking a duplicate
    resend). → Detect Claude's queued-message state (or keep waiting while the turn that was running at
    write time hasn't ended) before reporting "did not submit".
17. **MCPTests fail inside a Collie terminal** — `mcpListsTools`, `toolsFollowReach` fail already at `79a3926`;
    likely the test's spawned `collie mcp` inherits `COLLIE_*` env of the agent's terminal (Shepherd/reach).
    → Confirm the cause; clear `COLLIE_*` in the test before spawning (or the CLI ignores them in tests).
18. **`ArtifactTests.listStopsAskingPastItsDeadline` flaky under load** — fails when the machine is busy, passes
    alone (40/40 at `73fa4b3`). → Make the deadline check not depend on wall-clock timing under load.
