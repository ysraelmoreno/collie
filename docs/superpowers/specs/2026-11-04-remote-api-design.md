# Collie — Remote API for the iPhone app (design)

Date: 2026-11-04. Status: approved by the owner on 2026-11-04 (decisions at the end). Slice 1 in progress.

## Intent

`collie-ios` lets the user follow and steer the Mac's Collie from an iPhone: see paddocks and terminals, watch an
agent's output, ask an agent something, answer the prompts that block agents (permission dialogs, sandbox access
cards), read the work log and open Prévias. Today `collied` speaks only over its local Unix socket
(`UnixSocket.swift`, 0600 in a 0700 dir) and every "the user" action is gated by the admin token plus the signed-app
peer check (`AdminPeerCheck.swift`). This design adds a second, optional door for **one more kind of user principal —
a paired device —** with a fixed, small allowlist. It never exposes the admin surface.

## What is decided (by the brief)

- Optional listener inside `collied`, **off by default**. WebSocket over TLS, self-signed certificate whose
  fingerprint the phone pins at pairing.
- Pairing by QR shown in the Mac app (address, one-time secret, fingerprint); one token per device; revocation; a
  device list in the Mac app.
- Discovery: Bonjour on the LAN. Off the LAN: Tailscale (the user's own tailnet). No Collie relay in this phase.
- Exposed surface is an allowlist; admin commands are never reachable.
- APNs push only in phase 2.

## Non-goals (this phase)

- Raw keyboard input into a terminal from the phone (see Open decisions, D1).
- Creating/killing terminals, summon, herds, leashes, paddock create/land/delete, memory review, plug-ins, data
  export/import, sandbox mode — anything `admin.*`, `plugin.*`, `herd.*`, `memory.*` (beyond nothing), `panel.*`.
- Revoking sandbox grants, editing comments on Prévias, device mirroring (`ui.device`).
- Any internet-facing exposure, relay or port forwarding.

---

## 1. Transport

### Stack

- `Network.framework` in `collied`: `NWListener` with `NWProtocolTLS` (TLS 1.3 only) + `NWProtocolWebSocket`.
  No new package dependency (Package.swift today has only SwiftTerm). On iOS: `URLSessionWebSocketTask` with a
  delegate that pins the certificate (§4.1).
- One WebSocket per phone session. Text frames only, one JSON object per frame, UTF-8. Max inbound frame 256 KiB;
  outbound frames up to 1 MiB (terminal replay is chunked to that).
- WebSocket keepalive: server ping every 20 s; connection closed after 2 missed pongs. The phone reconnects with
  backoff (1, 2, 5, 10, 30 s cap) and always starts again with `session.hello` + `workspace.snapshot`.

### Identity (certificate)

- On first enable, `collied` creates a P-256 key and a self-signed X.509 cert (CN `Collie`, 10-year
  validity — the pin, not the CA chain, is the trust anchor) by running `/usr/bin/openssl` once
  (`req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve …`), packs it as
  PKCS#12 and loads it with `SecPKCS12Import` + `kSecImportToMemoryOnly` (macOS 15+) into a `SecIdentity` for
  `sec_protocol_options`.
  - `ec_param_enc:named_curve` is required: macOS's `openssl` is LibreSSL 3.3.6, which writes explicit curve
    parameters by default; Apple's TLS then fails every handshake with -9810 (errSSLInternal) although the key signs.
  - Why `openssl` stays (evaluated in slice 1): CryptoKit can sign a hand-built X.509, but `SecIdentity` without the
    Keychain only comes from a PKCS#12 import, and writing PKCS#12's PBE encryption by hand is more code and risk
    than one system binary. Revisit with D6 (Keychain).
- Files: `<root>/remote/identity.p12` (0600, random passphrase in `<root>/remote/identity.pass`, 0600). `<root>` is
  Collie's data dir, closed to sandboxed agents.
- Fingerprint = SHA-256 of the cert DER, shown as base64url (43 chars) and, for humans, as 4 groups of the hex prefix.
- **Rotate identity** (button in the device sheet): new key + cert; every paired device must re-pair (its pin breaks).
  That is the intended effect — it is the "I think the key leaked" button.
- **Backups (decided 2026-11-04):** a `.colliebackup` never carries `<root>/remote/` (`identity.p12`, `identity.pass`,
  the device store and its token hashes); an import can't plant one (`remote` isn't a backup part). Applying a restore
  moves this Mac's `remote/` into `.replaced-<epochMs>/` with the other replaced parts: the daemon then makes a new
  identity and every phone pairs again — the same effect as rotating the identity. (`DataBackup.applyPending`;
  test `DataBackupTests/remoteIdentityAndDevicesStayOutAndAreRetiredOnRestore`.)
- ponytail: key at rest in a 0600 file, not the Keychain. Ceiling: a free terminal (no sandbox) or open sandbox mode
  can read it and, with a network position, impersonate the Mac to a phone. Upgrade path: keep it in the login
  Keychain with an ACL for `collied` only.

### Bind, port, on/off

- Port: **47820/tcp** by default, editable in Preferências (1024–65535). Saved in the daemon settings file
  (`Settings` in `SandboxCommands.swift`, next to `terminalSandbox`/`googleFonts`) as
  `remote: {enabled: Bool, port: Int, tailscaleOnly: Bool}`; absent = disabled.
- Bind: all interfaces (needed for LAN + Tailscale's `utun`), but **every accepted connection is filtered by source
  address before the TLS handshake**: allowed are RFC 1918 (10/8, 172.16/12, 192.168/16), IPv4 link-local
  (169.254/16), IPv6 link-local (fe80::/10), IPv6 ULA (fc00::/7), Tailscale CGNAT (100.64.0.0/10) and Tailscale IPv6
  (fd7a:115c:a1e0::/48). Loopback is refused (an agent on the same Mac has no business there — it has the socket).
  With `tailscaleOnly`, only the two Tailscale ranges pass and Bonjour is not advertised.
- Each connection is labelled `via: lan | tailscale` from its source range (for the device sheet and the audit log).
- On/off: **Preferências → Celular → "Acesso pelo iPhone"** toggle. The app calls a new app-only command
  `admin.remote {enabled?, port?, tailscaleOnly?}` → returns the current state `{enabled, port, tailscaleOnly,
  fingerprint, listening, error?, addresses}`. The daemon starts/stops the listener live (no restart). Turning it off
  closes every remote connection at once. CLI (only outside a Collie terminal, like every `admin.*`):
  `collie admin remote on|off|status`.
- Listener failures (port in use, no identity) are reported in `admin.remote` (`listening: false, error`) and in the
  daemon log; they never stop the daemon.
- `run-isolated.sh` dev daemons use another root: they get their own identity and device store; give them another port.

### Discovery

- **LAN — Bonjour**: while enabled and not `tailscaleOnly`, `NWListener.service` advertises `_collie._tcp` with TXT
  `{v=1, fp=<first 16 hex of fingerprint>, id=<install id, random UUID>}`. The service name is the Mac's computer name.
  No token, no secret, nothing else. The phone browses with `NWBrowser` and matches `id` (saved at pairing); the
  full fingerprint is still pinned on connect.
- **Off the LAN — Tailscale**: the QR carries the Mac's Tailscale addresses when it has them (any interface address
  in 100.64.0.0/10 or fd7a:115c:a1e0::/48, read with `getifaddrs`) and, if `tailscale status --json` answers, the
  MagicDNS name. The phone tries, in order: last address that worked, Bonjour result, each QR host. No Collie relay.
- `admin.remote` returns `addresses: [{host, via}]` so the Mac UI can show "Alcançável por: Wi-Fi 192.168.1.10 ·
  Tailscale mac.tailnet.ts.net".

---

## 2. Pairing and devices

### Flow

1. Mac: **Preferências → Celular → Parear iPhone** (the app turns the listener on first: `pair.begin` refuses with
   `unavailable` while it is off). App calls
   `admin.remote.pair.begin` → `{pairingId, qr, expiresAt}`.
2. Daemon makes a **pairing secret**: 32 random bytes, base64url, in memory only, valid **5 min**, **single use**,
   at most **5 failed attempts**, at most one live pairing at a time (a new `begin` kills the old one).
3. QR content (a URL the iOS app registers):
   `collie://pair?v=1&id=<install id>&n=<Mac name>&h=<host1>,<host2>,…&p=<port>&fp=<fingerprint b64url>&s=<secret>`
4. Phone scans, connects to a host, **pins `fp`**, sends `pair` (§3) with the secret and its device name/model.
   The daemon answers at once with an offer `{pairingId, mac, code}` — `code` is a 6-digit number drawn for this
   attempt — and the phone shows "Confira no Mac: 482 913".
5. Mac app shows a confirmation with the same code: **"Parear ‘iPhone de Ysrael’ (iPhone 16, Wi-Fi 192.168.1.23)?
   Código 482 913 — Parear / Recusar"** (60 s, then refused). Rationale: a photo of the QR shouldn't be enough, and
   the code tells the user it is *this* phone.
6. Phone sends `pair.wait {pairingId}`; on Parear the daemon creates the device and returns its **device token**
   once. Phone stores `{deviceId, token, fp,
   install id, hosts, port}` in its Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: not in backups,
   not migrated to a new phone).

### Device token and store

- Token: 32 random bytes, base64url. Mac stores only **SHA-256(token)** — `<root>/remote/devices.json` (0600):
  `[{id, name, model, scope, pairedAt, lastSeenAt, lastAddress, lastVia}]` + hash. Comparison in constant time
  (`constantTimeEqual`, already used for the admin token).
- Scope per device: `full` (default) or `read` (no mutating command: §3 marks which). Set in the device sheet.
  Every message of a session reads the device from the store: a scope change or a revoke applies at the very next
  message (a revoked device's next message gets `unauthorized` and closing 4001).
- Token rotation: `session.hello` returns `rotate: <new token>` when the token is older than 90 days; the phone saves
  it and uses it from its next hello, which promotes it (the old one stops working then). No ack message. While a
  rotated token is pending, no second one is minted (a phone that lost it keeps the old token).
- No expiry otherwise: revocation is the off switch.

### Revocation and the device sheet (Mac app)

- **Preferências → Celular → Aparelhos**: one row per device — name, model, scope (Leitura / Completo), paired at,
  last seen (with Wi-Fi/Tailscale and address), live now (dot). Actions: **Revogar**, **Só leitura / Completo**,
  and at the bottom **Trocar certificado** (re-pair all) and the on/off toggle.
- Revogar → `admin.remote.devices.revoke {id}`: hash deleted, every live socket of that device closed at once with
  close code 4001 `revoked`. The phone wipes its credentials on 4001.
- **Close codes** (all sessions): 4000 `hello` (no hello in time, a request before hello, a refused hello), 4001
  `revoked`, 4002 `replaced` (a 5th session of one device closes its oldest), 4003 `disabled` (listener off, or
  restarted by Trocar certificado). Before the close frame the Mac sends a text frame
  `{"t":"closing","code":4001,"reason":"revoked"}`: `URLSessionWebSocketTask` only surfaces the standard close
  codes, so the phone reads the reason from this frame.
- The phone can also unpair itself: `device.unpair` (§3.10) — same effect as Revogar, for its own device only.
- New app-only commands: `admin.remote`, `admin.remote.pair.begin`, `admin.remote.pair.confirm {pairingId, accept}`,
  `admin.remote.devices` (list), `admin.remote.devices.revoke {id}`, `admin.remote.devices.scope {id, scope}`,
  `admin.remote.identity.rotate`. All under the existing `adminOnly` (admin token + signed-app peer check), so no
  agent can pair a device or read the secret. The pairing request reaches the app as a new `WorkspaceEvent`
  `remotePairing(pairingId, device: {name, model}, address, via)` on `ui.events`.

---

## 3. Exposed surface

### Envelope

Same shapes as the local protocol (`CollieProtocol/Envelope.swift`), minus `token`/`terminalId`/`cwd`:

```json
→ {"v":1,"id":"c-17","command":"approval.answer","args":{"id":"…","allow":true}}
← {"v":1,"id":"c-17","ok":true,"result":{"sent":true}}
← {"v":1,"id":"c-18","ok":false,"error":{"code":"notFound","message":"…"}}
```

Dates are ISO 8601 strings with UTC offset (`2026-11-04T20:31:07Z`), everywhere. Ids are lowercase UUID strings
unless stated otherwise.

Server-pushed frames carry `"t"` (no `id`): `{"t":"event","e":{…}}`, `{"t":"out","sub":"s1","d":"<base64>"}`, … —
the `StreamFrame` / `WorkspaceEvent` encodings, filtered (below). Unknown `t` values must be ignored by the phone
(forward compatibility). `v` mismatch → `unsupportedVersion`.

Error codes: the existing `ErrorCode` set. Used here: `unauthorized` (no/invalid/revoked hello, or `read` scope on a
mutating command), `notFound`, `notRunning`, `invalidArgs` (including any command not on the allowlist — same
message as an unknown command, so the admin surface isn't enumerable), `tooMany` (rate limit, with
`retryAfter` seconds in the message), `unavailable`, `conflict`, `timeout`, `unsupportedVersion`, `internal`.

### Wire details (for the iOS client, 2026-11-04)

- **URL**: `wss://<host>:<port>/` — any path is accepted, use `/`. No subprotocol, no extra header; never send
  `Origin` (refused).
- **QR `h=`**: comma-separated hosts, read with `URLComponents.queryItems` then split on `,`. v1 carries IPv4 only
  (LAN, then Tailscale 100.x). When IPv6 or the MagicDNS name come (slice 11): IPv6 in brackets (`[fd7a:…]`),
  MagicDNS as a plain host name in the same list.
- **Close codes**: only 4000 `hello`, 4001 `revoked`, 4002 `replaced`, 4003 `disabled` (also sent when the daemon
  stops or restarts — there is no 1001 from the Mac). Anything else, or a socket that drops without a frame
  (sleep, network), is a network loss: reconnect with backoff. A wrong pin never reaches the Mac: it is a TLS
  failure on the phone only.
- **Device credentials**: v1 has no device key pair (no ed25519). The phone's Keychain keeps
  `{deviceId, token, fp, installId, hosts, port}`; the token only travels inside the pinned TLS.
- **Envelope**: `pair` and `pair.wait` use the same `{v, id, command, args}` envelope. `pair.wait` must come on the
  connection that sent `pair` (whoever presented the secret gets the token); if that connection drops, the
  pairing is lost: generate a new QR.
- **`device.model`**: the commercial name when the app knows it ("iPhone 16 Pro"), else the identifier
  ("iPhone17,1"); ≤ 40 chars, shown on the Mac as is.
- **Event frames** (`{"t":"event","e":{…}}`, from slice 5): `e` is the remote projection with its own tag `t`, not
  the internal `WorkspaceEvent` keys. Ids are lowercase UUIDs, dates ISO 8601.
  ```json
  {"t":"status","terminalId":"…","badge":"idle|working|attention|stopped","since":"2026-11-04T20:31:07Z"}
  {"t":"attention","terminalId":"…","reason":"…"}
  {"t":"approval","approval":{"id","terminalId","terminal","paddock","kind","reason","prompt","at"}}
  {"t":"approval","terminalId":"…","cleared":true}
  {"t":"accessCard","card":{…the §3.7 card, with id…}}          // new or updated (internally sandboxDenied)
  {"t":"accessCardRemoved","id":"<card id>"}
  {"t":"askState","messageId":"…","state":"delivered|failed","reason":"…?"}
  {"t":"chat","message":{"id","at","role":"user|agent|collie","workId":null,"terminal":"Dev","text","truncated":false,"replyTo":null,"via":null}}
  {"t":"work","id":"<work id>"}                                  // changed: re-read with work.get
  {"t":"terminal","terminal":{…the §3.3 terminal projection…}}   // spawned or edited (upsert)
  {"t":"terminalRemoved","id":"…"}
  {"t":"paddock","paddock":{…}} {"t":"paddockRemoved","id"} {"t":"lot","lot":{…}} {"t":"lotRemoved","id"}
  {"t":"leash","a","b","on":true|false} {"t":"notify","terminalId","message"}
  ```
  A terminal exiting arrives as `status` with `badge: stopped`.
- **`approval.answer` with `sent: false`**: besides the pt-BR `reason`, a stable `code`: `stale` (no longer pending),
  `unknown` (too much output to check: look at the terminal), `failed` (the terminal didn't take the keys). Match
  on `code`, never on the text (slice 7).

### Dispatch (how it maps inside the daemon)

A new `RemoteGateway` in `CollieDaemonKit` owns the listener. After `session.hello` the connection carries a
**`remote(deviceId)` principal**. The gateway maps each allowlisted remote command to the internal command handler
**in-process** (the same functions `CommandRouter.route` calls for the app), never via the admin token. Where the
router today says "the app's alone" (`adminOnly`), the check becomes "app **or** a `full`-scope remote device" for
exactly the commands below — implemented as a `Principal` enum (`app | terminal(id) | remote(device)`) passed into
those handlers, not by forging an admin request. Results are **projected** (fields dropped) before leaving.

Legend: **R** read · **M** mutating (needs `full` scope; audited §4.3).

| Remote command | Kind | Derives from |
|---|---|---|
| `pair` / `pair.wait` | — | new (pairing store) |
| `session.hello` | — | new (device store) |
| `device.unpair` | — | `admin.remote.devices.revoke` on itself |
| `workspace.snapshot` | R | `ui.snapshot` + `work.approvals` + `access.list` + `work.list` + `artifact.list` |
| `events.subscribe` / `events.unsubscribe` | R | `ui.events` (+ work panel events) |
| `terminal.attach` / `terminal.detach` | R | `ui.attach` (output only) |
| `terminal.screen` | R | `check` (scrollback tail, ANSI stripped) |
| `agent.ask` | M | `work.chat.send` (`askAsUser`) |
| `chat.history` | R | `work.chat.history` |
| `work.status` | R | `work.chat.send` status questions (`StatusQuestion` → `WorkStatusText`) |
| `work.rerail` | M | `work.rerail` |
| `mac.reveal` | M | new: asks the Mac app to show a terminal / open a Prévia |
| `approvals.list` | R | `work.approvals` |
| `approval.answer` | M | `work.approve` |
| `approval.dismiss` | M | `work.approval.dismiss` |
| `access.cards` | R | `access.list` (admin view) |
| `access.grant` | M | `access.grant` |
| `access.deny` | M | `access.deny` |
| `work.list` / `work.get` / `work.summary` | R | `work.list` / `work.get` / `work.summary` (admin view) |
| `artifact.list` / `artifact.get` | R | `artifact.list` / `artifact.get` |
| `artifact.file` | R | new: reads an artifact's files / `collie-lib://` assets |

Everything else → `invalidArgs "Unknown command '<name>'"`.

### 3.1 `pair`, `pair.wait` (only before hello, only on a connection with no principal)

- `pair` args: `{secret, device: {name ≤ 60 chars, model ≤ 40}}` → at once `{pairingId, code: "482913",
  mac: {name, installId, collieVersion}, via: lan|tailscale}` (the iOS `PairingOffer`). The secret is consumed here.
- `pair.wait` args: `{pairingId}` — waits for the Mac's click (≤ 60 s) → `{deviceId, token, pairedAt,
  mac: {name, installId, collieVersion, keyFingerprint}}` (the iOS `MacInfo`).
- errors: `unauthorized` (wrong/expired/used secret — same message for all), `tooMany` (5 failures: secret dead),
  `timeout` (no click), `conflict` ("Recusado no Mac").

### 3.2 `session.hello`

- args: `{deviceId, token, app: {version, build}}` — must be the first message (else the socket closes, 4000).
  10 s to send it after the TLS handshake.
- result: `{protocol: 1, mac: {name, installId, build}, device: {id, name, scope}, rotate?: "<new token>"}`
- errors: `unauthorized` (unknown device / wrong token / revoked — one message; then closing 4000),
  `unsupportedVersion` (socket stays), `tooMany` (slice 7).
- Records `lastSeenAt`, `lastAddress` and `lastVia` on the device (the device sheet).

### 3.3 Paddocks, terminals, status — `workspace.snapshot`

- args: `{closedWorks?: Int (default 20, max 100), artifacts?: Int (default 50, max 200)}`.
- One round trip with everything the phone's screens show (the iOS `Snapshot`, also cached on the phone for the
  "Mac offline" state):
  ```json
  {"mac":{"name","installId","collieVersion","keyFingerprint","via":"lan|tailscale","pairedAt"},
   "paddocks":[{"id","name","branch":null,"base","status"}],
   "terminals":[{"id","name","preset","paddockId","isShepherd":true,"shepherdId":null,"shepherd":null,
                 "running":true,"badge":"idle|working|attention|stopped","badgeSince":"<iso>",
                 "activity":{"work":"Revisar PR #212","task":"Rodar testes"},
                 "sandbox":"sandboxed|free","lotId":null}],
   "lots":[{"id","name","members":["<terminal id>"]}],
   "leashes":[{"a":"<id>","b":"<id>"}],
   "approvals":[ …§3.7… ], "accessCards":[ …§3.7… ],
   "works":[ …§3.8, open ones + the last `closedWorks` closed… ],
   "artifacts":[ …§3.9… ]}
  ```
- New derived fields (none exists in the daemon today):
  - `shepherdId` / `shepherd` (name): the Shepherd whose leash the terminal is under — the same rule `chatSend`
    uses (`ConnectionGraph.reachable(...).filter(\.isShepherd)`, first by name); `null` for a Shepherd or a loose
    terminal. (iOS `leashedTo`.)
  - `badgeSince`: when the badge last changed (`StreamHub` keeps `since` per entry). The phone formats "Ocioso há
    42 min".
  - `activity`: from the work registry — the terminal's active work title and its first `inProgress` (else first
    `open`) task; `null` without an active work. The phone builds the line ("Revisar PR #212 · Rodar testes", or
    "Ocioso há 42 min" from `badgeSince`). ponytail: no screen scraping for activity; a terminal without a work shows
    only its badge age.
- `badge` stays the daemon's `StatusBadge` (`working`, not `running`; the phone maps it).
- Projection from `WorkspaceSnapshot`: drops panels (Prévias come via `artifact.*`), commands, env, cwd paths,
  plug-in list, layout frames.
- errors: none beyond auth.

### 3.3b Screen text — `terminal.screen`

- args: `{terminal, lines?: Int (default 200, max 500)}` → `{text, truncated}` — the `check` path (scrollback tail,
  ANSI stripped). For a list preview / a stopped terminal's last screen without opening a stream. (iOS `output`.)
- errors: `notFound`.

### 3.4 Events — `events.subscribe`

- args: `{}` → result `{sub: "ev"}`; then frames `{"t":"event","e":…}` until `events.unsubscribe` or close.
- Forwarded `WorkspaceEvent`s (projected like the snapshot): `spawned`, `exited`, `removed`, `status`, `attention`,
  `terminal`, `paddock`, `paddockRemoved`, `lot`, `lotRemoved`, `connected`/`disconnected` (leashes only),
  `notify`, `sandboxDenied` (an access card, new or updated — re-shaped to the §3.7 card with its `id`).
- New: `accessCardRemoved {id}` (granted, denied, or covered by a grant — on the Mac or a phone), so the phone drops
  it without a re-snapshot.
- Exact frame shapes: see "Wire details" above (they supersede the names in this list: `sandboxDenied` goes out as
  `accessCard`, `spawned`/`terminal` as `terminal`, `removed` as `terminalRemoved`, `exited` as `status: stopped`).
- Plus work-panel events, re-shaped: `approval` (`{approval}` or `{terminalId, cleared:true}` — from
  `approvalChanged`), `chat` (a new chat message — from the `work.chat` plugin event), `work` (a work changed —
  from `work.changed`).
- Dropped: `panel*`, `pluginEvent` (others), `herdApplied`, `sandboxDetection`, `confirmCorrection`,
  `pluginsChanged`, `remotePairing`.
- On overflow (send queue full) the server sends `{"t":"overflow","sub":"ev"}` and cuts the sub: the phone
  re-snapshots and re-subscribes (same contract as the app's `ui.events`).

### 3.5 Terminal output — `terminal.attach`

- args: `{terminal: <id>, replayBytes?: Int (default 64 KiB, max 256 KiB)}` → result `{sub: "t-<n>"}`
- Frames: `{"t":"replay","sub","d","truncated"}` first (tail of the scrollback, cut to `replayBytes`), then
  `{"t":"out","sub","d"}`, `{"t":"exited","sub","code"}`, `{"t":"overflow","sub"}`. `d` is base64 of raw PTY bytes
  (ANSI included: the phone renders with a terminal emulator, e.g. SwiftTerm's iOS view).
- **Output only**: `in` and `resize` frames from the phone are ignored. The terminal keeps the Mac's size; the phone
  scales or scrolls horizontally.
- Limits: 4 attached terminals per connection; output coalesced to ≤ 10 frames/s per sub (bytes joined, nothing
  dropped short of overflow).
- Free terminals (`sandbox: free`) can be attached (the user's own, read-only).
- errors: `notFound` (no such terminal), `notRunning` (a stopped terminal: no live scrollback to
  replay), `tooMany` (5th attach).
- Derives from `StreamHub.attach` (`Fanout.join`), with a remote `StreamConn` adapter and the replay cut.

### 3.6 Ask — `agent.ask` (M)

- args: `{terminal: <id>, text: ≤ 8000 chars, work?: <work id>}`
- result: `{messageId, queued: true}`; then an `askState {messageId, state: "delivered"}` event when the prompt is
  actually typed into the agent (`askAsUser` passes its readiness gate and writes — new hook point in the
  `AskCoordinator` waiter), or `state: "failed"` with `reason`. The agent's reply arrives later as a `chat` event
  with `replyTo: messageId` (or a Collie message saying why it wasn't sent). Phone states: fila → entregue →
  resposta.
- Derives from `work.chat.send` → `asks.askAsUser` — the same path the Work chat in the app uses, so the prompt
  counts as the user's (it is). Addressed by terminal **id**, not `@name` (names aren't unique across paddocks).
  Factor `chatSend`'s delivery part into a function both callers use.
- Refused: target not running (`notRunning`), shows an approval (`unavailable` "está esperando uma aprovação;
  responda o pedido primeiro"), preset `shell` or free terminal (`invalidArgs` — a phone must not type commands into
  a shell; see D1), empty or too long (`invalidArgs`).
- The chat message records `via: "<device name>"` (new optional field on `ChatMessage`) so the Mac chat shows
  "do iPhone".
- `chat.history` (R): args `{before?: <message id>, limit ≤ 200, terminal?: <id>}` → the `work.chat.history` page;
  with `terminal`, only messages to/from that terminal (filtered by `ChatMessage.terminal`, the terminal's current
  name — ponytail: a renamed terminal loses older messages from the filter; store the id on `ChatMessage` if that
  matters).
- The iOS `ask(terminalId:prompt:) -> String` is built on this: send, then await the `chat` event whose `replyTo` is
  the `messageId` (the daemon's own timeout is 30 min). No blocking remote call: a phone that goes to background
  drops its socket, and the reply is still in `chat.history` when it comes back.

### 3.6b Status questions and rerail

- `work.status` (R) args `{question: "whereAreWe"|"stuck"|"running"|"summary", terminal?: <id>}` → `{text}`
  (markdown). The status-question branch of `chatSend` (`StatusQuestion` → `WorkStatusText.answer` /
  `WorkSummary`), answered from the registry: no tokens, nothing typed. With `terminal`, scoped to its active work;
  without, all open works. Not posted to the Mac's chat (a read). (iOS `status`.)
- `work.rerail` (M) args `{terminal}` → `{injected, chars}` — `work.rerail` as the app calls it; its refusals
  unchanged (`unavailable` at an approval or a terminal that doesn't take a paste). (iOS `rerail`.)

### 3.6c Mac screen — `mac.reveal`

- `mac.reveal` (M) args `{terminal: <id>}` or `{artifact: <id>}` → `{}`. The daemon emits a new `WorkspaceEvent`
  `remoteReveal(terminal|artifact, device)` on `ui.events`; the Mac app centres the canvas on the terminal / opens the
  artifact as a Prévia. Changes nothing but the Mac's view. No-op (still ok) when the app isn't running.
  (iOS `MacAction.showTerminal`, `.openArtifact`.)
- **Not exposed**: `applyHerd` (`herd.apply` spawns terminals — admin surface, non-goal) and `muteTerminal` (no such
  concept in the daemon today; see D9).

### 3.10 `device.unpair`

- args: none → `{}`; then the socket closes with 4001. Deletes this device's hash (audited). (iOS `unpair`.)

### 3.7 Approvals — permission prompts and sandbox access cards

**Agent permission prompts** (`ApprovalTracker` → `Approval`):

- `approvals.list` (R) → `[{id, terminalId, terminal, paddock, kind, reason, prompt, at}]`
  (`work.approvals` plus `paddock`: the terminal's paddock name, `null` outside one; `kind` is the daemon's
  `ApprovalKind` as is — `yesNo|yesNoKey|menu|enter|unknown`; `prompt` = last 15 screen lines, ANSI stripped).
- `approval.answer` (M) args `{id, allow: Bool}` → `{sent, reason?}` — `work.approve`. `sent:false` reasons as
  today ("pedido não está mais pendente", "saída demais para conferir; olhe o terminal", "o terminal não recebeu a
  resposta"). Single use by construction: `ApprovalTracker.take(id)` consumes it; a second answer is stale.
- `approval.dismiss` (M) args `{id}` → `{dismissed}` — `work.approval.dismiss`.
- `kind: unknown` can't be answered remotely either (same as the app): the phone shows "olhe o terminal" and offers
  `terminal.attach`.

**Sandbox access cards** (`SandboxDenial`):

- `access.cards` (R) → `{cards: [{id, terminalId, terminal, paddock, op, path, folder, count, at, requested,
  reason, refusal, folderRefusal, isAgentConfig}], grants: [...]}` — the admin view of `access.list` (drops
  `silent`/`dropped`/`detection` internals).
  - `id` (new): a stable card id = base64url(SHA-256(terminal ‖ op ‖ folder))[0..16] — the card's existing
    dedup key (`SandboxCards.Key`) made addressable. Same card, same id across updates and reconnects.
  - `refusal` / `folderRefusal` (new on the wire): `SandboxGrantStore.refusal` for the path and for its folder
    (why only Negar is possible); `null` = can be opened.
  - `isAgentConfig` (new): the path is under an agent's global config (`~/.claude`, `~/.codex`, `~/.cursor`, and
    their files at home) — the phone shows an extra warning. Same list the Mac card uses when it gets one.
- `access.grant` (M) args `{card: <id>, folder?: Bool}` → `{grant, restarted, resumed}` — the gateway resolves the
  card to `{terminal, path, op→access}` and calls `access.grant`; all its checks (R26 path re-resolution,
  never-open list, closed paddocks) unchanged. Addressed by card id so the phone can't grant a path no card shows.
  **Remote grants are `scope: terminal` only** (`lot: true` is refused, `invalidArgs`; see D3). The phone must show
  the full path and "o terminal vai reiniciar".
- `access.deny` (M) args `{card: <id>}` → `{}` — `access.deny`.
- errors: `notFound` (card gone: answered on the Mac, or folded into another), `invalidArgs` (refusal).

### 3.8 Work log

- `work.list` (R) args `{closed?: Bool}` → works `[{id, title, terminalId, terminalName, paddockId, branch,
  openedAt, closedAt, closedBy, lastCommit, tasks: {open, inProgress, done, deferred, abandoned},
  jobs: {running, finished, gone, unknown}}]` (counts; full lists via `work.get`). `terminalName` survives a
  removed terminal only if the registry kept it (else `null`). `lastCommit` = last of `commits` ("sha assunto").
  ponytail: no per-job `lastSignalAt` — the daemon doesn't track job heartbeats; the phone uses `startedAt`/`state`.
- `work.get` (R) args `{id}` → the `Work` (tasks, jobs, notes, commits) as `work.get` returns it.
- `work.summary` (R) args `{id}` → `{markdown}` — `WorkSummary.make(...).markdown`. No `--natural` (on-device model
  on the Mac costs; can be added).
- errors: `notFound`.

### 3.9 Prévias / artifacts (HTML)

- `artifact.list` (R) args `{folder?}` → as `artifact.list` (id, kind, title, by, at, version, folder, thumbnail,
  status), minus local `path`/`file` fields, plus `live: Bool` (new) — a Prévia panel showing this artifact is open
  on the Mac now (from `ws.panels`).
- `artifact.get` (R) args `{id}` → one, same projection.
- `artifact.file` (R) args `{url}` where `url` is `collie-artifact://<id>/<relative path>` (the page and its files)
  or `collie-lib://…` (offline libs and fonts the pages reference), `offset?: Int` (default 0) →
  `{mime, size, offset, d: <base64>, done: Bool}`. **Chunked**: at most 512 KiB of file bytes per reply (≈ 683 KiB
  base64, under the 1 MiB frame); the phone asks again with `offset += decoded length` until `done`. Files up to
  8 MiB (the artifact page limit). The reply carries `etag` (version + mtime) so a file that changed between chunks
  is detected (`conflict`) and restarted. Paths resolved and confined to the artifact's folder / the lib store (no
  `..`, no symlink out — reuse the store's resolver).
- The phone renders pages in a `WKWebView` with a `WKURLSchemeHandler` for `collie-artifact://` and `collie-lib://`
  that calls `artifact.file`, **no network** (content rule list blocking http/https/ws), no JS bridge. A thumbnail
  is just `artifact.file` of its path.
- errors: `notFound`, `invalidArgs` (bad URL / path escape), `tooMany`.

---

## 4. Security

### 4.1 Hostile network

- TLS 1.3 only; the phone **pins the leaf certificate SHA-256** received in the QR (out of band). It accepts nothing
  else — no system trust, no "trust anyway". Pin mismatch → hard failure with "O certificado do Mac mudou. Pareie de
  novo." (also what Trocar certificado causes).
- No secret in the URL or in Bonjour; the token travels only inside TLS in `session.hello`.
- Connections from non-private source addresses are closed before TLS (§1). Loopback refused.
- Browsers: the WebSocket upgrade is rejected if it carries an `Origin` header (native clients don't send one), so a
  web page on the LAN can't drive it even if the user accepted the cert somewhere.

### 4.2 Token scope and limits

- A device token can only: hello, and the allowlist in §3 (and `read` scope: the R rows only). It can never become
  the admin token, can't reach `admin.*` (including `admin.remote.*`: a phone can't pair another phone or un-revoke
  itself), can't reach agent-only commands (`ask` as a terminal, `summon`…).
- Rate limits (token buckets, in the gateway):
  - per source address, before auth: 10 failed `hello`/`pair` per minute → refuse new connections from it for 60 s;
  - pairing secret: 5 failures total, then dead;
  - per device: 30 requests/s (burst 60); mutating commands 30/min; `artifact.file` 20 MiB/min;
  - connections: 4 per device, 16 total; the oldest of a device is closed (4002 `replaced`) on the 5th.
  - `tooMany` carries `retryAfter`.
- Inbound frame cap 256 KiB; `text` caps as the internal commands.

### 4.3 Audit — who approved, from where

- Every M command and every pair / hello / revoke appends one line to `<root>/remote/audit.jsonl` (0600, rotated at
  5 MiB, keep 2): `{at, device, deviceName, address, via, command, target (terminal/approval/path), result: ok|error
  code}`. Never the token, never chat text.
- The decisions show where the user already looks:
  - approvals: the chat line becomes "Aprovado do iPhone de Ysrael (Tailscale)" / "Negado do …" (today:
    "Aprovado"/"Negado");
  - access grants: `SandboxGrant` gets `by: {device, via}` (optional), shown in Preferências → Sandbox next to the
    grant;
  - asks: `ChatMessage.via` (§3.6).
- **InputProvenance (R12)**: unchanged semantics. `approval.answer` writes the dialog keys with `origin: .user`
  (the user's decision, like the app's click); `agent.ask` goes through `askAsUser` (the user's prompt). Remote
  writes never call `InputProvenance.typed` (there is no remote keyboard), so they can't be mistaken for keystrokes,
  and they don't taint — the same as the app's chat/approvals today. The **device** is recorded in the audit log and
  on the chat message, not in `InputProvenance` (it tracks *whether* the user wrote a prompt, not *where from*).

### 4.4 Mac offline / asleep

- The phone shows the last snapshot greyed with "Mac inacessível desde 14:02" and keeps retrying (backoff). No
  queued actions: an approval answered offline would be stale anyway; the UI disables M actions while disconnected.
- Daemon restart / listener toggled: sockets close (1001 / 4003 `disabled`); the phone reconnects, hellos, re-snapshots.
  Nothing is lost on the Mac side (approvals and cards live in the daemon; the phone is a view).
- Sleep: the listener sleeps with the Mac. Optional Preferência **"Manter o Mac acordado enquanto agentes trabalham
  (com iPhone pareado)"**: an `IOPMAssertion` (`PreventUserIdleSystemSleep`) held only while the listener is on, at
  least one device is paired, and some terminal is `working` or `attention`. Doesn't override lid-closed on battery.
  On the LAN, macOS "Wake for network access" + the Bonjour Sleep Proxy may wake the Mac for `_collie._tcp`; best
  effort, not promised.

### 4.5 Threats

| Threat | Mitigation | Residual |
|---|---|---|
| MITM on café Wi-Fi | pinned cert from QR; TLS 1.3 | none while the key is secret |
| Someone on the LAN probes the port | TLS before anything; hello required in 10 s; per-IP failure lockout | they learn a Collie runs there (Bonjour already says so; `tailscaleOnly` hides it) |
| QR photographed | single use, 5 min, Mac-side confirm click | — |
| Device token leaked (backup, logs) | Keychain ThisDeviceOnly; hash-only on Mac; never logged; Revogar; 90-day rotation | until revoked, holder = the user's phone powers |
| Stolen/unlocked phone | `read` scope option; the iOS app gates M actions behind Face ID (client duty — the server can't verify it); Revogar from the Mac | a jailbroken phone skips Face ID |
| Replay | TLS; pairing secret single use; approval ids single use (`take`), stale check; grants re-check the path | — |
| Agent on the same Mac reaches the port | loopback refused; device store holds hashes only; key/store in `<root>` (closed to sandboxed agents); pairing only via `adminOnly` | free terminals / open mode can read `<root>` (key ceiling in §1) |
| Prompt injection via displayed output | terminal output shown as terminal text; Prévias in a no-network WKWebView without bridge | a page can still *lie* in its content |
| DoS of the daemon | per-connection caps, bounded send queues (existing `StreamConn` backpressure), frame caps | a LAN peer can keep the port busy; the local socket is unaffected |
| Exposure beyond LAN/tailnet (router port forward) | source-range filter refuses public addresses | a user who NATs a public IP to a private one bypasses the filter — documented, not supported |

---

## 5. Push (APNs) — phase 2 only

What it would take:

- An Apple Developer team with Push Notifications on the iOS app id; an APNs auth key (.p8). That key is the
  **developer's**, not the user's: it can't ship inside every Mac's Collie. So pushes need a **sender holding the
  key** — a small Collie push relay (e.g. a serverless function) — which conflicts with "no relay" in phase 1.
- Minimal-trust relay: at pairing the phone sends its APNs device token and a random 32-byte push key to the Mac.
  The Mac sends the relay `{apnsDeviceToken, ciphertext}` where ciphertext = AES-GCM(push key, {kind, title,
  terminalId, approvalId}); the relay can't read it. The iOS app's Notification Service Extension decrypts and shows
  "Agente pede permissão: …". The relay authenticates Macs by a per-install key registered at pairing and rate-limits.
- Events worth a push: new approval, new access card, agent turn finished after an `agent.ask`, `notify`.
- Optional later: Live Activity for a working agent; actionable notification "Aprovar/Negar" — which would then need
  the phone to reach the Mac (still needs connectivity) or the relay to carry the answer back (a bigger trust step).
- Alternative without a relay: none on stock iOS (background WebSockets are suspended); BGAppRefresh is too coarse.

---

## 6. Implementation plan (small, testable slices)

Tests run with `swift test --filter <Suite>` on the touched suites only. Each slice is mergeable alone; nothing is
reachable from the network until slice 3.

0. **Spike (throwaway)** — macOS 15: openssl-made P-256 identity + `SecPKCS12Import(kSecImportToMemoryOnly)` +
   `NWListener` TLS 1.3 + WebSocket; iOS simulator `URLSessionWebSocketTask` pinning the SHA-256. Proves the stack and
   that `collied` (LaunchAgent, sandbox-free) can listen without a firewall prompt surprise. Output: a note in
   `docs/superpowers/notes/`.
1. **Settings + identity + listener (done, 2026-11-04)** — `remote` in `CollieSettings`; `RemoteIdentity`
   (create/load/rotate, fingerprint); `RemoteAddress` source filter; `RemoteGateway` (NWListener TLS 1.3 +
   WebSocket, filter before TLS, `Origin` refused, 16 connections max; any message → close 4000 until slice 3);
   `admin.remote [on|off|status] [--port] [--tailscale-only on|off]` (app only) → `{enabled, port, tailscaleOnly,
   listening, listeningPort, fingerprint, error}`; listener started with the daemon when left on. `port: 0` = any
   free port (tests, dev daemons). The spike (old slice 0) was folded in: the tests drive a real pinned
   `URLSessionWebSocketTask`. Tests: `RemoteAddressTests`, `RemoteIdentityTests`, `RemoteAdminTests`,
   `CommandsTests/adminRemoteFromTheCLI`. Not done here: firewall prompt check on a real install, Bonjour (slice 11),
   rotate command (`admin.remote.identity.rotate`, slice 10 with the device sheet).
2. **Device store + pairing logic, no network (done, 2026-11-04)** — `RemoteDevices` (`devices.json` 0600: SHA-256 of
   the token only, constant-time verify, revoke, scope `full|read`; each device keeps the identity fingerprint it
   pinned, and a device of another identity is dropped at verify; `RemoteIdentity.rotate(devices:)` revokes all) and
   `RemotePairing` (one live pairing, secret single use / 5 min / 5 failures → `tooMany`, one refusal message for
   wrong, expired and used, 6-digit code, Mac accept/refuse, 60 s confirm timeout read off the clock). Tests:
   `RemoteDevicesTests`, `RemotePairingTests` (injected clock, no sleep). Moved to slice 3: the 90-day token
   rotation in `session.hello` and `lastSeenAt`/`lastAddress` (both written by hello).
3. **Pair, hello and the app's commands (done, 2026-11-04)** — `RemoteSession` per connection: 10 s hello deadline
   (`DaemonConfig.remoteHelloDeadline`), `pair` / `pair.wait` (bound to the connection that claimed; woken by the
   Mac's click; the accepted device is created once) / `session.hello` (lastSeen/address/via, 90-day token rotation),
   close codes with the `closing` frame, 4 sessions per device. App commands: `admin.remote.pair.begin` (QR with
   the Mac's LAN/Tailscale IPv4 hosts and `install-id`), `.pair.confirm`, `.devices`, `.devices.revoke` (closes
   live sessions, 4001), `.devices.scope`, `.identity.rotate` (revokes all, restarts: 4003). Event
   `remotePairing(RemotePairingRequest)` on `ui.events` for the app's dialog. Tests: `RemoteSessionTests` (real
   pinned `URLSessionWebSocketTask`), `RemoteTokenRotationTests`. Its scope is enforced from slice 4 (read live on every message).
4. **Remote principal + read surface (done, 2026-11-04)** — `RemoteSurface.commands` (allowlist, read/mutating,
   never `admin.*`); the session re-reads its device on every message (revoke → 4001, read scope → `unauthorized` on
   mutating ones, both at the next message), then calls `CommandRouter.remoteRequest` in-process (no admin token).
   Explicit projections: `workspace.snapshot` with `shepherdId`/`shepherd`, `badgeSince` (`StreamHub.badgeSince`),
   `activity`, approval `paddock`, card `id`/`refusal`/`folderRefusal`/`isAgentConfig`, work counts, artifact
   `live`; `terminal.screen`, `work.list/get/summary`, `approvals.list`, `access.cards`, `chat.history`
   (`terminal` filter), `artifact.list/get`. Mutating entries pass the gate and answer `unavailable` until slices
   7-8. Tests: `RemoteSurfaceTests` (every non-allowlisted command incl. all `admin.*` → Unknown command; no token,
   identity file, cwd, command or root path in the snapshot; live scope/revoke). Artifact `kind` is the store's
   (`agent|export`), not the iOS mock's template kinds.
5. **Events** — filtered `events.subscribe` incl. `approval`/`chat`/`work`. Tests: filter table, overflow → frame
   and cut.
6. **Terminal output** — `terminal.attach/detach` adapter over `StreamHub`, replay cut, coalescing, 4-per-connection
   cap, `in`/`resize` ignored. Tests: `RemoteAttachTests` with a fake PTY.
7. **Mutations + audit + limits** — `approval.answer/dismiss`, `access.grant/deny` (terminal scope only), audit log,
   chat "do iPhone", `SandboxGrant.by`, token buckets, `read` scope enforcement. Tests: audit line per M command,
   stale approval, read scope refused, lot scope refused, rate-limit refusal with `retryAfter`.
8. **Ask, status, rerail, Mac view** — factor `chatSend` delivery and its status branch; `agent.ask` by terminal id
   with the shell/free/attention refusals; `ChatMessage.via`; `work.status`; `work.rerail`; `mac.reveal` +
   `remoteReveal` event (the app's handler lands with slice 10). Tests: `RemoteAskTests`, `RemoteStatusTests`.
9. **Artifact files** — `artifact.file` for `collie-artifact://` and `collie-lib://`, confinement, 8 MiB cap,
   per-device byte budget. Tests: path-escape table, symlink out refused.
10. **Mac app UI** — Preferências → Celular (toggle, port, Só Tailscale, reachable addresses, fingerprint), Parear
    sheet with QR (CoreImage `CIQRCodeGenerator`) + confirm dialog on `remotePairing`, Aparelhos list (revoke, scope,
    Trocar certificado), "do iPhone" in the chat. Manual check in the dev app.
11. **Discovery** — Bonjour advertise (`NWListener.service`, TXT), Tailscale addresses via `getifaddrs` (+ optional
    MagicDNS via `tailscale status --json`). Tests: address classification; Bonjour checked by hand.
12. **Keep-awake option** — IOPMAssertion held/released by state. Test: the state machine (assert when on + paired +
    working; release otherwise).

Phase 2 (separate design): APNs relay (§5), raw input (D1), lot-scope grants (D3).

---

## Decisions

Closed by the owner on 2026-11-04 (all as proposed):

- **D1 — Raw terminal input from the phone: not in v1.** Output only; `agent.ask` refuses shells. If it comes later:
  `full` + a separate per-device "teclado" switch, Face ID per session, `InputProvenance.typed` fed like the app's
  keyboard.
- **D2 — Mac-side confirm click at pairing: yes** (with the 6-digit code on both sides).
- **D3 — Lot-scope sandbox grants from the phone: no.** Remote grants are `scope: terminal` only.
- **D4 — Default scope of a new device: `full`.** `full` never includes a keyboard (D1).
- **D5 — Port: fixed 47820** (editable in Preferências; easy Tailscale ACLs; without a token nobody gets in).
- **D6 — Key at rest: 0600 file in v1**, login Keychain later (an ACL for a `collied` without a stable signature
  is work).
- **D7 — Keep-awake preference: later.**
- **D8 — `tailscaleOnly` default: false** (LAN on). The Mac confirm click + pinned cert cover hostile Wi-Fi.
- **D9 — `muteTerminal` / `applyHerd`: out of v1.** `herd.apply` spawns terminals (admin surface); mute isn't
  defined in the daemon.

## Appendix — iOS contract mapping (`collie-ios` `Collie/Data/CollieService.swift`)

| iOS | Remote |
|---|---|
| `beginPairing(qr:)` → `PairingOffer{macName, collieVersion, route, code}` | `pair` (`route` = `via`: `lan`/`tailscale`; no `relay` in v1) |
| `confirmPairing` → `MacInfo` | `pair.wait` (`latencyMs` measured by the phone: WS ping RTT) |
| `unpair` | `device.unpair` |
| `snapshot` | `workspace.snapshot` (+ `events.subscribe` to keep it live) |
| `output(terminalId:lines:)` | `terminal.screen` (the app has no terminal emulator: while a terminal's screen is open it re-reads `terminal.screen` every 2 s — a running agent's output changes without a `status`/`attention` event — and otherwise only on those events; well inside the per-device limits of §4.2. `terminal.attach` is there for a later emulator view) |
| `artifactHTML(id:)` | `artifact.file collie-artifact://<id>/index.html` (+ its assets via the scheme handler) |
| `answer` / `dismiss` | `approval.answer` / `approval.dismiss` (`sent:false` + "não está mais pendente" = `.notPending`) |
| `grant(cardId:folder:lot:)` / `deny(cardId:)` | `access.grant {card, folder}` / `access.deny {card}` (`lot` refused, D3) |
| `ask(terminalId:prompt:)` | `agent.ask` → `askState delivered` → `chat` event with `replyTo` |
| `status(_:terminalId:)` | `work.status` |
| `rerail(terminalId:)` | `work.rerail` |
| `perform(.showTerminal/.openArtifact)` | `mac.reveal` |
| `perform(.muteTerminal/.applyHerd)` | not exposed (D9) |
| `CollieError.macOffline` | socket down / reconnect failing |
| `TerminalStatus.running` | badge `working` |

Review by the iOS terminal (2026-11-04, `collie-ios/docs/handoff-primeiro-corte.md`), resolved in this draft:
rerail, token-free status questions, plain-text screen, `badgeSince` + `activity`, ask "entregue" state,
`chat.history {terminal}`, card `refusal`/`folderRefusal`/`isAgentConfig` + `accessCardRemoved`, artifact `live`,
`work.list` counts/`terminalName`/`closedBy`/`lastCommit`, 6-digit pairing code, `mac.reveal`, chunked
`artifact.file`, ISO 8601 dates, full `ApprovalKind`. Not taken: per-job `lastSignalAt` (no daemon data). QR
validity is **5 min** (the prototype's "2 min" text should follow).
