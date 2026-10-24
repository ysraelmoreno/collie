# Plan 2P — Access Cards You Can't Miss

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a sandboxed agent is blocked, the user sees it on the node itself and in a macOS notification, and can act in one click; cards that can never be granted don't pile up as noise.

**Architecture:** Today the only entry is `AccessBadge` (`Sources/CollieApp/AccessViews.swift:37`): a `CollieTag` "acesso N" inside the node header (`TerminalNodeView.swift:471`) that is secretly a button opening `AccessPopover`. The user didn't find it (2026-10-24: "como eu libero? Não tem nenhum painel"), so agents waited on 20 cards. Add: a strip overlaid at the bottom of the terminal body when the node has open cards; a notification per new card (existing `Notifier`, click focuses the node and opens the popover); the tag styled as a button. Cards the store would refuse (`SandboxDenial.refusal != nil`, e.g. Collie's own data dir) collapse into one quiet line with a single "Dispensar".

**Tech Stack:** Swift 6.2, SwiftUI, UserNotifications (existing `Notifier`).

**Spec:** user report 2026-10-24 + agreed shape: strip on the terminal ("O agente pediu acesso — ver"), macOS notification on each new card.

## Global Constraints

- The strip is an overlay on the terminal body: it never changes the body frame (2H/2I: no PTY resize from a card appearing).
- Notifications: one per new card (same `sameCard` key = no re-notify on count updates); at most one per terminal per 30 s (a denial storm → one notification, then the count on the strip). No notification while the app is frontmost and the node is on screen — the strip is enough.
- Notification body shows the verb and the path's last two components only (`AccessCopy.shown`), never a reason text longer than 80 chars.
- Granting stays app-only (admin) and keeps the card's existing buttons and copy; the strip only opens the popover.
- UI copy pt-BR, original wording.

## Review Focus

1. 20 open cards on one node: strip says "20 pedidos de acesso", one click opens the popover scrolled to the newest.
2. Node scrolled off screen or on another paddock: notification click switches paddock, centers the node, opens the popover (reuse `notifier.onFocus`).
3. Only refused cards (all for `~/Library/Application Support/Collie/…`): strip shows the quiet variant; "Dispensar" denies them all at once; the agent gets the normal denial.
4. Zoomed-out canvas (≤ 50 %, node remounted at low raster): strip still readable or hidden with the header tag still showing the count.
5. Card resolved from another place (granted in the popover of a lot view): strip disappears from every node it was on.

---

### Task 1: Strip on the node + clearer tag

**Files:**
- Modify: `Sources/CollieApp/AccessViews.swift` (`AccessBadge` button look; new `AccessStrip`; `AccessPopover` scroll to newest)
- Modify: `Sources/CollieApp/TerminalNodeView.swift` (overlay `AccessStrip` at the bottom of the body, sandboxed terminals only; the popover's `open` state lifted so the strip and the tag share it)
- Modify: `Sources/CollieClient/DaemonClient.swift` (`func denyAll(_ cards: [SandboxDenial]) async throws`, loops the existing `deny`)
- Test: `Tests/CollieAppTests/` (new `AccessStripTests.swift`: pure `AccessStrip.Model(cards:)` → kind/text)

**Interfaces:**
- Produces: `AccessStrip.Model(cards: [SandboxDenial])` with `kind: .none | .pending(Int) | .refusedOnly(Int)` and `text: String`.

- [ ] **Step 1: Tests** `noCardsNoStrip`; `pendingText` (3 grantable → "3 pedidos de acesso — ver"; 1 → "O agente pediu acesso — ver"); `refusedOnly` (2 refused → `.refusedOnly(2)`, "2 acessos bloqueados de propósito"); `mixedCountsGrantableOnly` (2 grantable + 5 refused → `.pending(2)`).
- [ ] **Step 2:** Run `swift test --filter AccessStripTests` → FAIL; implement the model → PASS.
- [ ] **Step 3:** View: strip 28 pt high, full body width, `collieAttention` background for `.pending` with the text and a "Ver" button (opens the popover); `.refusedOnly`: muted background, text, `.help` "Pastas do próprio Collie e segredos nunca são liberadas", "Dispensar" (`denyAll`). Tag: add a `chevron.down` and a hover highlight so it reads as a button. Hidden when the node's zoom raster is below 0.5 (Review Focus 4).
- [ ] **Step 4: Manual:** in a sandboxed Claude terminal `cat ~/Documents/x` → strip appears; Ver → popover; Liberar → strip gone; `cat "$HOME/Library/Application Support/Collie/workspace.json"` → quiet strip, Dispensar clears it. Resize the node while the strip shows: one PTY resize per step, none when the strip appears.
- [ ] **Step 5: Commit** `feat(app): access strip on the node; access tag looks like a button`.

### Task 2: Notification per new card

**Files:**
- Modify: `Sources/CollieClient/DaemonClient.swift` (`.sandboxDenied`: call `onAccessCard?(d)` only when the card is new, not on an update of an existing one)
- Modify: `Sources/CollieApp/CollieApp.swift` (wire `onAccessCard` → `Notifier`; focus handler also opens the node's access popover)
- Modify: `Sources/CollieApp/Notifier.swift` (`func notifyAccess(_ d: SandboxDenial, name: String)` with the 30 s per-terminal throttle and the frontmost-and-visible skip)
- Test: `Tests/CollieAppTests/NotifierThrottleTests.swift` (pure throttle: `AccessNotifyGate.shouldPost(terminal:at:) -> Bool`)

- [ ] **Step 1: Tests** `firstCardPosts`, `secondWithin30sSkipped`, `after30sPosts`, `otherTerminalIndependent`, `updateOfSameCardNeverPosts` (client side: `onAccessCard` not called on count update), `refusedCardNeverPosts`.
- [ ] **Step 2:** Implement; tests PASS.
- [ ] **Step 3:** Copy: title "<nome> pediu acesso", body "Quer <ler|escrever|apagar|executar> …/<últimas duas partes>". Click → existing `onFocus` (paddock switch + center) then open that node's popover.
- [ ] **Step 4: Manual** (Review Focus 2): node on another paddock, trigger a denial with Collie in the background → notification → click → right paddock, node centered, popover open.
- [ ] **Step 5: Commit** `feat(app): notify on new access cards`.
