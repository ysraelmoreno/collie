# `collie work run`: unattended work loop — Design

Status: draft for the owner's approval (name and the three decisions settled 2026-11-17). Nothing here is built; `scripts/dev/work-loop.sh` is the prototype it replaces.

## Why

The owner wants to hand a list of tasks to Collie and come back to finished, verified commits ("ships while I sleep",
the Ralph loop). Today that takes a Shepherd delegating by hand and the owner watching.

A prototype (`scripts/dev/work-loop.sh`) ran three real tasks on 2026-11-17:

| Task | Agent | Result |
|---|---|---|
| Relevance floor (memory item 1) | Claude | passed on attempt 1, 19 min |
| Same task | Cursor | failed twice (86 min) with the first script; passed on attempt 2 (9.5 min) after the script fixes |
| Cursor turn end in the daemon | Claude | committed in 2 min; result pending when this was written |

What it showed:

- A fresh agent per attempt plus a log of what failed works: the second attempt fixed what the first broke.
- The script, not the agent, has to decide "done". Every time the agent's word or the turn's end was trusted, it failed.
- The script's limits are the daemon's strengths: it guesses the end of a turn from the screen, its state is loose files,
  the agent's terminal vanishes before the owner can look, and the loop dies with the script's process.

## What Ralph does, and what we keep

Ralph is an external `for` loop: each iteration starts a fresh agent, which picks the next story from `prd.json`, works,
commits, and prints `<promise>COMPLETE</promise>` when it thinks everything is done.

| Ralph | Here |
|---|---|
| Fresh agent per iteration | Kept: it is what stops errors piling up in one context |
| `progress.txt` carried across iterations | Kept, as the work's notes |
| The agent picks the task | Dropped: the loop picks, in order |
| The agent declares completion | Dropped: a check command decides |
| Runs on the working branch | Dropped: runs in a paddock; landing stays with the owner |

## Goals

- One command starts an unattended loop over a work's open tasks.
- A task counts as done only when its check passes, there is a new commit and no tracked file is left dirty.
- The owner can watch and stop it from the canvas and the CLI.
- Works with any agent Collie can summon; nothing in the loop is specific to one LLM.

## Non-goals

- Writing the task list or the checks (the PRD step): the owner or the Shepherd does that.
- Parallel tasks inside one loop. Parallel = one loop per paddock.
- Pushing, landing or opening PRs.

## Anti-goals

- A task passing on the agent's word.
- The loop touching a worktree other agents are using.
- A check that runs with more access than the agent that wrote the code.

## Approaches

Where the loop is defined. The owner asked for these four to be weighed.

1. **A command, driven by the daemon** (`collie work run`). The daemon summons, waits for the real end of turn, runs the
   check, decides, retries. State lives in the work registry. *Picked.*
2. **The paddock.** Not a loop by itself, but the loop needs what a paddock gives: its own worktree and a land step the
   owner controls. *Picked, together with 1.*
3. **Terminal creation** (`summon --loop`). One terminal re-prompted until done. Rejected: same context every round
   (the thing Ralph avoids), and a Cursor terminal cannot tell the daemon its turn ended.
4. **The prompt** ("repeat until the tests pass"). Rejected: the agent judges its own work. It is Ralph's weak point
   and the prototype's first failure.

Name. The owner floated `collie loopwork`; `collie work run` was chosen. The tasks, notes and status already live under
`collie work`; a loop is a way of running a work, not a second kind of work. A separate `loopwork` noun would need its
own list/status/stop and its own panel.

## How it works

### Tasks get a spec and a check

```
collie work task add <title>… [--spec <file>] [--check <command>]
```

- `spec`: a Markdown file with what to build and the acceptance criteria. Read when the attempt starts.
- `check`: a shell command run in the paddock's worktree. Exit 0 = the check passes.
- Both are stored in the work registry, not in the repo, so the loop's agent cannot edit the check it is judged by.

`WorkTask` gains optional `spec`, `check`, `tries` and `lastFailure`; older files decode.

### Starting, watching, stopping

```
collie work run [--tries 3] [--timeout 3600] [--preset <preset>] [--model <model>] [--max <n>]
collie work stop
collie work status        # gains the loop's state: task, attempt, last failure
```

- `work run` returns at once; the loop runs in the daemon. A notice reaches the starter when it ends.
- It runs on the caller's active work and needs that work to be in a paddock.
- One loop per paddock at a time.
- `work stop` ends it after the current attempt's check (the agent is dismissed first).

### One attempt

1. Pick the first open task.
2. Summon a fresh agent terminal in the work's paddock, named `loop-<task>-<n>`.
3. Send the prompt: the spec, the check command as text, the work's notes from earlier attempts, and the rules
   (commit before running a build, no push, no land, nobody will answer questions).
4. Wait for the end of the turn as the daemon already knows it for that preset (see "Any agent, not agent types"),
   bounded by `--timeout`.
5. Run the check in the worktree, under the same sandbox profile as the agent's terminal.
6. Decide:
   - **Pass** = check exit 0 **and** a new commit **and** no tracked file dirty. The task becomes `done`.
   - **Fail**: the reason and the tail of the check's output go into the work's notes; the attempt's work is saved as a
     patch under the work's data; the worktree is reset to where the attempt started.
7. After `--tries` failures the task becomes `deferred` with the reason, and the loop moves on.

The agent's terminal stays open until its check has finished, so the owner can see what it did. It is dismissed on a
pass; on the last failed attempt it is kept.

A turn that hits `--timeout` is not a failure by itself: the check still decides. (The prototype got this wrong.)

### When it ends

All tasks are `done` or `deferred`, `--max` attempts were used, or `work stop`. The paddock's status goes
to review as usual; the owner lands.

A daemon restart stops the loop. Its state is in the registry, so `collie work run` again continues from the next open
task. No automatic resume.

## How the owner starts a loop: `/collie:loop`

The owner never types `collie work run`. Like `work start` and `summon`, it is what an agent calls. The owner works in
natural language, and a normal (sequential) work starts with no command at all. A loop is expensive (several agents,
hours), so it has one explicit entry:

```
/collie:loop <what to do>
```

The name is the owner's decision (`collie:` namespace; it also avoids Claude Code's own `/loop`).

What the command makes the agent (usually the Shepherd) do:

1. Start a work, or use the active one, and break the request into tasks, each with a spec and a check.
2. **Show the task list and every check to the owner and wait for approval.** The owner is the one who can tell whether
   a check measures the result.
3. Call `collie work run`, then report when the loop ends.

Asked in plain language ("deixa rodando até passar"), an agent may offer `/collie:loop`; it never starts a loop without
the owner's approval of the list.

## A loop is a work being run, not another kind of work

There is one `Work` type. A work is sequential by default, as today: the agent of its terminal does the tasks in one
conversation and says when each is done. `work run` puts a work into a loop; `work stop` or the end of the loop takes
it out.

| | Sequential work (today) | Work in a loop |
|---|---|---|
| How it starts | natural language; the agent just works | `/collie:loop`, which ends in `collie work run` |
| Who does the tasks | one agent, start to end | a fresh `loop-<task>-<n>` agent per attempt |
| Memory between tasks | the whole conversation | none; only the notes of what failed |
| Who says "done" | the agent | the daemon, by the check |
| When it goes wrong | the agent retries in the same conversation | discard, start clean, up to N attempts |
| The work's terminal | busy doing the work | free: it started the loop and only watches |

Rules:

- **No mixed works.** `work run` needs every open task to have a check; it refuses and names the ones that lack it.
  A check matters only to a loop: outside one, a task behaves as today.
- The loop's agents do not get a work of their own: each attempt is a job of the work that started it (a new
  `JobKind.loop`), so the registry, summary and learning see one work.
- `Work` gains an optional `loop` field (state `running | stopped | finished`, current task, attempt, tries, timeout,
  agent). Absent = sequential. `work status`, `work list` and the work panel show "em laço" with the current task and
  attempt (`2/3`).
- While a loop runs, the starter and the Shepherd may keep talking; they must not edit the worktree.

## Decisions (owner, 2026-11-17)

1. **Name**: `collie work run`.
2. **The loop needs the worktree to itself.** The reset between attempts and the "no tracked file dirty" rule both break
   if another agent is editing it. `work run` refuses to start while another agent terminal of that paddock is working
   (the starter and the Shepherd do not count). A loop that should run beside other agents gets its own paddock, created
   by the owner; `work run` never creates one.
3. **Who may start a loop**: a Shepherd, or the app. Corrected while planning: `summon` is Shepherd-only in the daemon
   (leashes are the only permission), and a loop summons agents, so letting any terminal start one would widen that.

## What the design does not solve

A check verifies the spec, not the outcome. The relevance-floor task passed with 35 green tests and changes nothing
for the owner: its floor applies to English vectors and the owner writes Portuguese. The loop makes it cheap to
produce green code; whoever writes the task still has to write a check that measures the result.

## Any agent, not agent types

The loop knows nothing about Claude, Cursor or Codex. It uses three things every terminal preset already has: `summon`
(any preset or custom command), `ask` (the daemon's own end of turn for that preset) and `dismiss`. A new LLM that
Collie can summon works in a loop with no change to the loop.

The one thing that varies is how sure the end of turn is, and `ask` already says so in its result (`source`): a hook,
or idleness. The loop's rule is the same for everyone: an end reported by a hook is trusted; an end reported by
idleness is trusted only once the attempt has a new commit, otherwise the loop keeps waiting up to `--timeout`. The
check decides in every case.

## Slices

1. Task `spec`/`check`, `work run`/`stop`, the attempt cycle for any summonable agent, status in the CLI.
2. `/collie:loop` (Claude and Cursor terminals) and the loop's state in the work panel.

## Left to the builder

- How `/collie:loop` reaches the agents. Collie ships no slash command today: orientation comes from the session-start
  text and the MCP tools. For Claude, `plugin:command` is a plugin's command, so a `collie` plugin loaded per terminal
  is the likely route (to verify against the installed Claude Code). Cursor already gets a per-terminal `collie` plugin
  (`--plugin-dir`); whether a Cursor plugin can carry a command is to verify. Nothing is written to `~/.claude`,
  `~/.cursor` or the repo.
- The prompt's exact text (start from the prototype's).
- Where the attempt patches live and when they are deleted.
- How the check is run sandboxed (the paddock's `pending()` already runs git under a terminal's profile).
- Test doubles for the agent: the prototype's stub (`collie` that commits or not) is the model.
