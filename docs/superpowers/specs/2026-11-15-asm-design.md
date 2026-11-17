# ASM — Active Shared Memory (design)

Date: 2026-11-15. Status: draft for approval.

## Intent and why

Today every Collie memory lives on one Mac. The only way a team shares what its agents learned is committing
`<repo>/.collie/memory/` to git: slow, tied to one repo, and the knowledge still concentrates in whoever runs the agents
that learned it. The owner wants **ASM**: a cloud service a company deploys (AWS as the reference) holding **shared
memory spaces** (e.g. "Checkout", "Delivery", "Cart" — any structure the company wants: team, domain, product). Access
control decides who reads and writes each space, like Confluence spaces, but the content is agent memory. Agents' work
keeps the spaces updated, and every connected Collie receives changes **in real time over SSE**, so the next prompt of any
member's agent already has them. Goal: knowledge stops depending on one person or one place.

Product for any company; **first pilot is the owner's own team**.

## What the owner decided

- A self-deployable cloud service (container + Postgres), AWS as reference deploy, not AWS-only.
- Spaces with per-space access control.
- Real time = memory updated by use; readers receive updates via SSE.
- Writes go straight in as **provisional** (no approval queue): the local curator scrubs before sending, other members'
  use confirms it, their contest drops it.
- Server stack: **Swift on Linux (Hummingbird + PostgresNIO)**, sharing wire types with the daemon.
- Pilot first with invite tokens; design ready for company SSO (OIDC).

## Goals

- An agent's prompt gets relevant memories from the spaces its repo is bound to and its user may read, ranked with the
  local ones, inside the existing prompt budget.
- A memory written, superseded, flagged or archived on one Mac reaches every subscribed Mac within seconds.
- A correction anywhere stops the wrong memory from being injected everywhere.
- Offline or server down: agents keep working with the last mirrored state; hooks never wait on the network.
- Every change is attributable (who, which machine, when) and auditable per space.
- One container image + Postgres runs the whole service; one instance is enough for the pilot, N instances work.

## Non-goals (v1)

- SAML, SCIM provisioning, web admin UI, billing, multi-region, cross-company spaces.
- End-to-end encryption (server reads plaintext; TLS in transit, disk encryption at rest by the host — RDS).
- Moving the curator, embeddings or ranking to the server.
- Syncing lot, paddock or global memories. Lots stay local and isolated.
- Replacing repo memory (`.collie/memory/`): project scope stays as is.

## Anti-goals (failure even if it "works")

- A secret, token, customer data, absolute local path or personal note reaches a space.
- A user without access to a space learns its content — or that it exists.
- A repo file makes Collie connect to, or push memories to, a server the user never logged into.
- A memory corrected or archived in a space keeps being injected on any Mac.
- The server being slow or down slows or blocks an agent.
- One person (an admin, an approver) becomes required for knowledge to flow — the thing ASM exists to remove.
- Lot content leaks into a space (lot isolation from the learning spec stays).

## Constraints (from the code)

- Collie is macOS-only; `CollieCore` imports `CryptoKit`/`Darwin`, the daemon networks with `Network.framework`. The
  server needs Linux, so shared types go in a **new Foundation-only target**, not in `CollieCore`.
- The package has one dependency (SwiftTerm). Server dependencies (Hummingbird 2, PostgresNIO) belong to the server
  target only; `collied`/`collie`/`CollieApp` must not link them.
- Memory files are truth, FTS5 index is cache (`MemoryStore`, `MemoryIndex`). Lot/global stores are 0700/0600 in the
  app's data dir (`MemoryStore(secureRoot:)`) — the space mirror follows the same rule.
- Prompt injection has a 2048-byte budget shared with lot posts; hooks have a 5 s budget and fail open.
- The curator is the headless curator (`claude -p` today; the provider becomes choosable in spec 2026-11-17-curator-provider) with a daily cap. It may be absent.
- Lifecycle rules (provisional → earned → long-term, flags, contested) exist for project scope
  (`2026-11-13-memory-lifecycle-design.md`), with daemon-owned state.
- Deterministic scrub exists: `LotBoards.scrub` (`Sources/CollieDaemonKit/Lots/LotBoard.swift:167`).
- Tests: only changed/created tests via `--filter`, never the full suite.

## Approaches (server stack)

- **A. Swift on Linux, Hummingbird + PostgresNIO** — one language, wire types shared with the daemon; cost: 2–3 new
  deps on a server-only target, a Linux-clean shared module, thinner OIDC ecosystem (JWT validation is enough).
- **B. Go or TypeScript server** — mature OIDC/SAML/SCIM/admin ecosystem; cost: two stacks, contract duplicated.
- **C. AWS serverless (API Gateway + Lambda + DynamoDB)** — scales to zero; dropped: long-lived SSE is awkward on
  Lambda and it locks the product to AWS.
- Git-based sync dropped: not real time.
- **Chosen by the owner: A.** SAML later via an identity proxy (Cognito, Dex) in front, without changing the server.

## Architecture

```
 Mac (each member)                                          Company cloud
 ┌───────────────────────────────┐                         ┌──────────────────────────────┐
 │ agent ─hooks─▶ collied        │   HTTPS REST (writes,   │ asm-server (container, N×)   │
 │   MemoryService (rank+inject) │ ◀── snapshot) ────────▶ │  auth · ACL · versioning     │
 │   SpaceSync actor ────────────┼── SSE /v1/stream ◀───── │  SSE fan-out                 │
 │   space mirror (0600 files)   │                         │      │ LISTEN/NOTIFY         │
 │   outbox (offline writes)     │                         │  Postgres (truth + audit)    │
 │   curator: classify + scrub   │                         └──────────────────────────────┘
 └───────────────────────────────┘
```

The local Collie stays the brain (capture, curator, ranking, injection). The server is deliberately dumb: store,
authorize, version, fan out, audit, and apply the deterministic shared-lifecycle rules.

### New targets

- `CollieSpaceWire` (Foundation only, builds on Linux and macOS): `SpaceMemory`, `SpaceEvent`, request/response
  bodies, error codes. Daemon maps `SpaceMemory` ⇄ `MemoryRecord`.
- `asm-server` (executable, Linux + macOS): Hummingbird 2, PostgresNIO, depends only on `CollieSpaceWire`. Includes
  `asm-server migrate` and `asm-server admin …` subcommands (create space, grant, invite) — the v1 admin surface.
- Daemon side (in `CollieDaemonKit`): `Spaces/SpaceSync.swift` (actor: login, snapshot, SSE, outbox), mirror store, scope
  wiring. Networking via `URLSession` (`bytes(for:)` for SSE) — no new client dependency.

### Data model (Postgres)

- `principals` (id, kind `user|device`, display name, `oidc_sub` nullable, disabled) — invite users and OIDC users live
  in the same table, so pilot → SSO needs no migration of memberships.
- `device_tokens` (id, principal, machine name, sha256 of token, created, last seen, revoked) — one per Mac, revocable.
- `invites` (sha256 of code, space grants, expires, used_by).
- `spaces` (id, slug unique, name, created_by, archived).
- `memberships` (space, principal or `oidc_group`, role `reader|writer|admin`).
- `memories` (id uuid, space, kind, subject, title, body, status, tier, version int, author principal, origin machine,
  supersedes, superseded_by, created_at, updated_at). Body ≤ 4 KB.
- `memory_events` (seq bigserial, space, memory id, type `created|superseded|flagged|used|tier|archived|restored`,
  payload jsonb, actor, at) — append-only: it is the audit log, the SSE replay source and the cursor.
- `signals` (memory, principal, day, kind `use|useful|wrong|outdated`, reason) unique per (memory, principal, day, kind).

### API (`/v1`, JSON, bearer device token)

- `GET /spaces` — only spaces the caller can read (others are invisible: 404, never 403).
- `GET /spaces/{slug}/memories?after=<seq>` — snapshot of active + recently changed, plus current `seq`.
- `POST /spaces/{slug}/memories` — create (writer). Server re-applies the deterministic scrub and size limits.
- `POST /memories/{id}/supersede` (writer, `If-Match: version`) — new record replaces old in one transaction.
- `POST /signals` — batched uses/flags (reader).
- `GET /stream?spaces=a,b` — SSE; `id:` = event seq; `Last-Event-ID` resumes; heartbeat comment every 25 s. A cursor
  older than retained events returns `event: resync` → client re-snapshots.
- `GET /spaces/{slug}/events` (admin) — audit read/export.
- Auth: `POST /auth/invite` (code → device token); later `POST /auth/oidc` (device-code flow ID token → device token).

### Fan-out

Insert into `memory_events` → trigger `NOTIFY asm_events, '<seq>'`. Each server instance `LISTEN`s, loads the event,
and writes it to its open streams whose ACL (computed at subscribe) includes the space. A membership change or token
revocation closes the affected streams; the client reconnects and gets the new ACL. One instance for the pilot; behind an
ALB, N instances work unchanged.

### Binding a repo to spaces

`<repo>/.collie/spaces.json` (committed): `{"server": "https://asm.example.com", "spaces": ["checkout","payments"],
"write": "checkout"}`. An agent sees the **intersection** of the repo's spaces and the spaces its user may read.
**Security:** the daemon uses a repo's `server` only if the user already logged into that exact server (matched by URL
and server identity key stored at login); otherwise it shows "repo wants space server X — log in?" in the app and does
nothing. A repo can never make Collie connect or push anywhere by itself.

### Read path (client)

1. On daemon start / login: for each bound+readable space, snapshot `after=cursor`, write to the mirror
   `<root>/spaces/<server-id>/<slug>/` (`MemoryStore(secureRoot:)`), save cursor.
2. Open one SSE stream for all subscribed spaces; apply each event to the mirror and the FTS index; save cursor.
3. Reconnect with exponential backoff (1 s → 60 s) and `Last-Event-ID`.
4. New scope `MemoryScope.space` with `spaceId` (+ server id) on `MemoryRecord`. `contextParts` adds bound space
   mirrors to the candidates; ranking (FTS + embeddings + platform filter) is unchanged; lines carry the space slug,
   e.g. `[checkout]`, and the existing `(provisória)`/`(contestada)` tags.
5. Offline: the mirror is used as is. Nothing in the hook path touches the network.

### Write path (client)

1. Existing capture (corrections, decisions, pitfalls, conversation capture) produces a candidate, as today.
2. If the repo is bound and the user is a writer, a new curator job **classifies** it: `project`, `space:<slug>` (only a
   bound space), or `none`; and **rewrites** it for a team reader without personal content. Lot-origin candidates and
   global (about-the-user) candidates are never classified to a space.
3. Deterministic scrub (`LotBoards.scrub` + home dir/absolute paths, emails, high-entropy strings) runs after the
   curator, and again on the server.
4. The record goes to the **outbox** (`<root>/spaces/outbox.jsonl`, 0600) and is POSTed; on failure retried with
   backoff; server idempotency by record id.
5. Without the curator (no model, or cap reached): **no automatic push**. Explicit routes still work with the
   deterministic scrub: `collie memory save --space <slug>`, `collie memory promote <id> --space <slug>` (MCP
   equivalents), so agents and users can share on purpose.

### Shared lifecycle (server-owned, deterministic)

- New space memory: `tier = provisional`, injected everywhere tagged `(provisória)`.
- Uses: clients batch their existing "useful use" signal (lifecycle spec) per space memory to `POST /signals`.
  **Earned** when used by ≥ 2 distinct principals on ≥ 2 distinct days (starting numbers, calibrate with stats).
  **Long-term** when used by ≥ 4 principals over ≥ 14 days, or pinned by a space admin.
- Flags: one `wrong|outdated` → `contested` (still injected, tagged `(contestada)`). Two distinct principals →
  archived (reversible by the author or an admin via restore). Admin archive → archived at once.
- **Supersede by any writer acts at once, wiki-style (owner's decision).** The old record is archived (`superseded`),
  the new one starts `provisional`; the event records who replaced it, and the old author or an admin can restore.
- Every tier/status change is a `memory_events` row, so it propagates over SSE and every mirror stops injecting an
  archived or superseded memory on the next prompt.
- Provisional never used by anyone for 30 days → archived.

### App

- Preferences → "Memória compartilhada": server URL, invite code / login, connection status, spaces list.
- Memory panel: new tab "Espaços" — per space: last events, contested memories, the user's own pending outbox.
- Repo-binding prompt ("this repo wants spaces X at server Y") shown here.

### Deploy

- `Dockerfile` (swift:6.2 build stage, slim runtime), `docker-compose.yml` (server + Postgres) for local and pilot.
- AWS reference (doc, not IaC in v1): ECS Fargate + RDS Postgres + ALB with idle timeout ≥ 300 s, TLS via ACM, secrets in
  Secrets Manager.

## Development plan (phases)

Each phase ends with something runnable; phases 1–5 make the pilot.

0. **Foundation.** `CollieSpaceWire` target + `asm-server` skeleton in `Package.swift`; Linux build check in a
   swift:6.2 container; daemon targets unchanged.
1. **Server core.** Migrations, principals/tokens/invites, spaces/memberships, `admin` CLI, memories CRUD + supersede,
   `memory_events`, SSE with NOTIFY fan-out, ACL invisibility. Tests run against a Postgres container, skipped when
   `ASM_TEST_DATABASE_URL` is unset.
2. **Read path (pilot milestone: team reads shared memory).** Daemon login via invite, `spaces.json` binding with the
   known-server rule, snapshot + SSE mirror, `.space` scope in ranking/injection, offline behaviour.
3. **Explicit write.** `memory save --space`, `memory promote --space`, outbox, both scrubs, supersede from Collie.
4. **Automatic write.** Curator classify + rewrite job, budget order inside the daily cap (after corrections).
5. **Shared lifecycle + app.** Signals batching, server tier rules, contested/archived propagation, Preferences page,
   "Espaços" tab, Dockerfile/compose, AWS reference doc. **Pilot with the owner's team.**
6. **Product.** OIDC device-code login, group → membership mapping, audit export, rate limits per device. Later: SAML
   via proxy, web admin, SCIM.

## Decisions after the builder check (my calls; the owner can override)

- **Server identity key.** `asm-server migrate` generates an Ed25519 keypair once (private key in the DB or a secret).
  `GET /v1/identity?nonce=<random>` returns server id, public key and the signed nonce. At login the daemon stores
  `{url, server id, public key}`; every connect re-challenges. TLS certs rotate freely (no cert pinning). A repo's
  `server` is honoured only when URL and key match a stored login.
- **Principal = user.** Device tokens belong to a user principal (`device_tokens.principal` → `principals.kind = user`);
  `principals.kind` drops `device`. Signals, flags and tier counts are per user, so one person with two Macs counts once.
- **Local passes skip space records.** `LifecyclePass`, `Consolidation`, `MemoryCleanup`, `MemoryVerify`, pitfall-class
  merging and `MemoryDigest` auto-actions never write mirror files; only `SpaceSync` writes the mirror. The digest may
  show space items read-only.
- **A local flag acts locally at once.** `wrong|outdated` on a space memory hides it from that user's injections
  immediately (local overlay, kept until the server event arrives or 7 days), and goes to the outbox. Other Macs follow
  when the server applies the rule.
- **Kinds allowed in a space (v1):** `decision`, `pitfall` (instances, not classes: `hits` stays local), `feedback`
  about the codebase/team (never about the user), `procedure`. `map` excluded (repo-relative paths span repos). Server
  rejects others.
- **Automatic writes go only to the repo's `write` space.** Explicit `--space <slug>` may target any bound space where
  the user is a writer.
- **Revocation deletes the mirror.** On each stream connect the server sends `event: spaces` with the caller's readable
  slugs; the client deletes mirrors (files + index rows + outbox entries) of spaces not listed or no longer bound. Same
  on token revocation (401 → delete all mirrors of that server).

## Left to the builder

- Exact Hummingbird/PostgresNIO versions (pin exact, like SwiftTerm) and the migration mechanism (plain SQL files in
  order is enough).
- Exact scrub patterns for high-entropy strings and emails.
- Event retention (start: keep all; `resync` path must still exist and be tested).
- How the mirror/FTS index rows mark the space (reuse the lot pattern where possible).
