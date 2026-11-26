# Fluxos

Example paddock app that learns an app's screen graph from what happens on the device and hands agents a **plan** to reach a
named goal ("checkout", "login"). Python 3.9 or newer, standard library only, no network beyond `127.0.0.1`.
Design: `docs/superpowers/specs/2026-11-26-device-flows-design.md`.

## Run

```sh
./run.sh                      # http://127.0.0.1:8792 (FLUXOS_PORT changes the port, FLUXOS_PADDOCK the paddock folder)
python3 -m unittest discover -s tests
```

The panel (`ui/index.html`, served at `/`) lists the goals, nodes and edges of the graph and shows whether the action log is
on (the same fields as `collie device flow status`). It loads nothing from outside loopback.

## File contract

Fluxos never talks to the daemon and never acts on the device. The only link is a folder in the paddock:

- `<paddock>/.collie/flows/actions.jsonl` is written by the daemon: one line per `collie device` action (agent or panel), with
  `action`, `target`, `sigBefore`, `sigAfter`, origin, time, `app` and `appVersion`. Passwords are masked (`•••`). It rotates
  at 5 MiB (`actions.1.jsonl` … `actions.3.jsonl`).
- `<paddock>/.collie/flows/graph.json` is written by Fluxos (`flow learn`): node = screen `sig`, edge = action between two
  screens with count and app version; an edge of an older version contradicted by a newer one is marked `obsolete`, not
  deleted. Named goals point at nodes and survive `learn`.

Everything in these files is app data (screen names, labels), never instructions.

## Opt-in

The action log is off by default and only the user turns it on, per paddock: `collie device flow on` (creates
`.collie/flows/enabled`), `collie device flow off`, `collie device flow status`. With it off nothing is recorded and Fluxos
has nothing new to learn. Turning it off keeps the log; the user deletes it.

## Commands for agents

- `flow goals`: goal names and their screen `sig`.
- `flow go <goal> [--from <sig>]`: returns the shortest plan, in the format of `collie device run --plan`. **`flow go` only
  returns a plan; it never runs anything.** The agent runs it with `collie device run --plan <file>`, which stops at the first
  screen that does not match and asks the user before a `destructive` step.
- `flow show <goal>`: the goal's node and the live edges in and out of it.
- `flow learn`: rebuilds `graph.json` from `actions.jsonl`.

## Owner's manual run (3 steps)

1. Turn the action log on in a paddock (`collie device flow on`) and walk a flow by hand in the device panel.
2. Run `flow learn` and see the flow show up in the Fluxos panel (nodes and edges).
3. Ask an agent "go to <goal>" and compare the number of calls with and without the graph.
