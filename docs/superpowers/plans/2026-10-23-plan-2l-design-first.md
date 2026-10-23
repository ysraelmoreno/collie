# Plan 2L — Design First: the Shepherd Offers a FigCraft Design for UI Work

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Without the user spelling it out, a Shepherd given UI work uses the paddock's design panel if there is one, otherwise asks once whether to design it in FigCraft first (or just does / skips it, per a remembered workspace preference); a built-in herd sets up the designer → implementer → tester chain.

**Architecture:** The behavior lives in the orientation text the daemon already injects at session start (`CollieDaemonKit/CollieOrientation.swift`, called from `MemoryCommands.swift:129`), not in a skill installed in the user's config — so it works the same for Claude, Codex and Cursor. A new workspace field `designFirst` (`ask` | `always` | `never`, default `ask`) picks the Shepherd's line; a Shepherd command records the user's answer; Preferences shows it. A third factory herd chains the roles.

**Tech Stack:** Swift 6.2, SwiftUI (Preferences), existing herd format.

**Spec:** user request 2026-10-23 ("adicionar uma skill default para pelo menos perguntar ou já mandar criar um design… ou quebra o fluxo?") and the agreed shape: trigger only on UI work, ask at most once per workspace, existing design panel used without asking, preference ask/always/never, herd "Feature com design".

## Global Constraints

- Nothing written to the user's global config (`~/.claude`, `~/.codex`, …); orientation only.
- Only Shepherds get the design-first line; other terminals keep today's "Design panel …" line when they reach one.
- UI work = new screen, new flow, or visible change to an interface. Not: backend, refactor, tests, bug without visual change, docs.
- Orientation stays ≤ 1200 chars (`CollieOrientation.limit`) in the worst case (Shepherd, 3 names per group, all plug-ins).
- Orientation text is English (agents); herd texts and UI copy pt-BR, original wording.
- `designFirst` is decoded with a default (old `workspace.json` without it → `ask`) and only written by the new command or Preferences.

## Review Focus

1. Non-UI task in a workspace set to `ask`: the Shepherd must not ask about design (the line must say when not to).
2. User answers "não, nunca" in chat: the Shepherd records `never` and stops asking in new sessions too.
3. Paddock with a design panel the Shepherd isn't leashed to: it should leash it to the implementer (it can, as Shepherd) rather than open a second one.
4. `always` with no design system active: the designer still works (FigCraft default), and the Shepherd says which file it created.
5. Legacy workspace file without the field loads, saves, and round-trips with `ask`.

---

### Task 1: Workspace preference + command

**Files:**
- Modify: `Sources/CollieCore/Workspace.swift` (field, coding keys, decode default)
- Modify: `Sources/CollieProtocol/Commands.swift` (spec), the daemon handler next to the other design commands (`Sources/CollieDaemonKit/DesignCommands.swift`)
- Test: `Tests/CollieCoreTests/WorkspaceTests.swift`, `Tests/CollieDaemonKitTests/DesignCommandsTests.swift`

**Interfaces:**
- Produces: `public enum DesignFirst: String, Codable, Sendable, CaseIterable { case ask, always, never }`; `Workspace.designFirst: DesignFirst` (default `.ask`).
- Produces: command `design.prefer` — `collie design prefer ask|always|never` → `{designFirst}`; no arg → returns the current value. Setting is Shepherd-only (or admin); reading is open to every terminal.

- [ ] **Step 1: Tests** `decodesWithoutDesignFirst` (→ `.ask`), `roundTripsDesignFirst`, `preferSetsValue` (Shepherd), `preferRefusedForNonShepherd` (`notShepherd`), `preferReadsForAnyone`, `preferRejectsUnknown` (`invalidArgs` naming the allowed values).
- [ ] **Step 2:** Implement; emit the usual workspace-changed event so the app refreshes.
- [ ] **Step 3:** `swift test --filter "WorkspaceTests|DesignCommandsTests"` → PASS. Commit `feat(design): workspace design-first preference`.

### Task 2: Shepherd orientation line

**Files:**
- Modify: `Sources/CollieDaemonKit/CollieOrientation.swift` (`text`/`build` gain `designFirst: DesignFirst`), its caller in `MemoryCommands.swift`
- Test: `Tests/CollieDaemonKitTests/CollieOrientationTests.swift`

**Interfaces:**
- Consumes: `Workspace.designFirst`.

The Shepherd gets exactly one of these lines (original text, keep it this short):
- design panel reachable or in its paddock: `- UI work (new screen, flow or visible change): use design panel <names> first; leash it to whoever implements. Not for backend, refactors or tests.`
- none, `ask`: `- UI work (new screen, flow or visible change) and no design panel: ask the user once whether to design it in FigCraft first. Save the answer: collie design prefer always|never. Not for backend, refactors or tests.`
- none, `always`: `- UI work (new screen, flow or visible change): open a design panel (collie panel open design --file <feature>) and have it designed before implementing. Not for backend, refactors or tests.`
- `never`: no line.

- [ ] **Step 1: Tests** `shepherdAskLine`, `shepherdAlwaysLine`, `shepherdNeverNoLine`, `shepherdWithPanelUsesIt` (wins over every preference), `nonShepherdNoDesignFirstLine`, `worstCaseFitsLimit` (Shepherd, long names, all plug-ins, each preference → `count <= 1200`).
- [ ] **Step 2:** Implement; if the worst case overflows, shorten other lines, never drop the design-first line before the name lists shrink.
- [ ] **Step 3:** Tests PASS. Commit `feat(orientation): Shepherd offers a design for UI work`.

### Task 3: Preferences + herd "Feature com design"

**Files:**
- Modify: `Sources/CollieApp/PreferencesView.swift` (picker), `Sources/CollieClient/DaemonClient.swift` (call `design.prefer`)
- Modify: `Sources/CollieCore/Herd.swift` (`Herd.factory`)
- Modify: `README.md` (Design section: one paragraph on design-first and the herd)
- Test: `Tests/CollieCoreTests/HerdTests.swift`

**Interfaces:**
- Consumes: `design.prefer`.

- [ ] **Step 1:** Preferences: "Design antes da interface" picker — "Perguntar" (`ask`), "Sempre" (`always`), "Nunca" (`never`) — for the current workspace; disabled while disconnected.
- [ ] **Step 2: Test** `factoryFeatureComDesignValid` (passes `HerdFormat.validate`; leashes: pastor–designer, pastor–interface, pastor–tester, designer–design, interface–design, interface–navegador, tester–design, tester–navegador).
- [ ] **Step 3:** Add herd `id: "feature-com-design"`, name "Feature com design", `wantsPaddock: true`, summary "Pastor, designer, interface e tester: desenha no FigCraft, implementa e confere contra o design." Terminals (all `.claude`, roles original pt-BR):
  - `pastor` (Shepherd): coordinates; asks the designer first, passes the approved screens to the interface, asks the tester for a comparison before calling it done.
  - `designer`: builds the screens in the Design panel (`collie design …`), using the active design system; tells the Pastor which screens are ready.
  - `interface`: implements from `collie design inspect`/`export`; checks in the Navegador.
  - `tester`: compares `collie design screenshot` with `collie browser screenshot` (and devices if any) at the widths the Pastor names; reports differences with both images.
  Panels: `design` (state `file: "Feature"`), `navegador` (browser). Frames: terminals `row(0…3)`, panels `below(1)`, `below(2)`.
- [ ] **Step 4:** README paragraph. `swift test` → PASS. Commit `feat(herds): Feature com design; design-first in Preferences`.
