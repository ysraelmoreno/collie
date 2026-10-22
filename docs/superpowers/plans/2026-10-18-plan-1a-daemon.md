# Plano 1A — Daemon, protocolo e terminais — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um daemon `orqd` headless que mantém terminais (PTY) de agentes, autentica cada terminal por token, e permite que agentes conversem (`list`, `ask`, `check`) via CLI `orq` e via MCP, com resposta obtida por hooks estruturados do agente e fallback por ociosidade.

**Architecture:** Swift Package com bibliotecas pequenas (`OrqProtocol`, `OrqCore`, `OrqTerminal`, `OrqDaemonKit`) e dois executáveis (`orqd`, `orq`). O daemon escuta um socket Unix (uma requisição JSON por conexão, uma linha de resposta). Todo comando é descrito uma vez numa tabela (`CommandSpec`) da qual derivam o parser do CLI e o schema MCP. A UI (plano 1B) será só mais um cliente deste daemon.

**Tech Stack:** Swift 6.2 (strict concurrency, actors), SwiftPM, Swift Testing (`import Testing`), Darwin `forkpty`, BSD sockets + `DispatchSource`. Sem dependências externas.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (§4, §5, §9, §10). Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Comportamento de referência: a análise de referência (local, não publicada) §3.4.

## Global Constraints

- macOS deployment target **15.0**; Swift tools 6.2; language mode Swift 6.
- Sem App Sandbox; sem dependências de terceiros nesta fase.
- Clean-room: não copiar código/textos do Maestri. Nada com prefixo `maestri` (convive com o Maestri instalado): CLI `orq`, daemon `orqd`, env `ORQ_*`, `TERM_PROGRAM=Orq`.
- Protocolo **versionado** (`v: 1`), erros tipados, timeouts explícitos, resultado nunca truncado silenciosamente (`truncated: true` quando cortar).
- Auth local: token secreto por terminal (32 bytes aleatórios, hex), comparação em tempo constante; socket em diretório `0700`.
- Nunca instalar hooks/skills em arquivos globais do usuário (`~/.claude/settings.json`, `~/.codex/config.toml`): hooks vão por flag de lançamento.
- Anti-metas: RAM limitada (scrollback em memória com teto), nada bloqueante em thread compartilhada, chamadas que falham dão erro claro e rápido.

## Review Focus

1. **Agente alvo nunca termina o turno** → `ask` retorna erro `timeout` após `--timeout` (padrão 1800 s), sem travar o daemon. Teste: Task 8 `askTimesOut`.
2. **Processo alvo morre no meio de um `ask`** → erro `notRunning` em < 1 s, não espera timeout. Teste: Task 8 `askFailsFastWhenTargetExits`.
3. **Saída gigante (MBs) do terminal** → RAM do buffer fica ≤ teto; `check`/`ask` marcam `truncated: true`. Teste: Task 3 `capsMemoryUnderFlood` + Task 8 `askMarksTruncated`.
4. **Daemon caiu e deixou socket velho / daemon não está rodando** → `orqd` remove socket órfão ao subir; `orq` diz "daemon não está rodando" (erro `daemonUnavailable`, exit 3) em vez de travar. Teste: Task 6 `removesStaleSocket`, Task 10 `cliReportsDaemonDown`.
5. **Prompt com sequências de controle** (ex.: `ESC[201~` fechando o bracketed paste, `\u{03}`) → removidas antes da injeção; texto Unicode/multilinha preservado. Teste: Task 4 `sanitizesPasteTerminator`.

---

## File Structure

```
Package.swift
Sources/
  OrqProtocol/   JSONValue.swift · Envelope.swift · Commands.swift · ArgvParser.swift · MCPSchema.swift
  OrqCore/       Paths.swift · Workspace.swift · WorkspaceStore.swift · ConnectionGraph.swift
  OrqTerminal/   ScrollbackBuffer.swift · ANSI.swift · PTYProcess.swift · PromptInjector.swift
  OrqDaemonKit/  UnixSocket.swift · AuthRegistry.swift · TerminalRegistry.swift · AgentLaunch.swift
                 AskCoordinator.swift · CommandRouter.swift · Daemon.swift
  orqd/          main.swift
  orq/           main.swift · HookCommands.swift · MCPServer.swift
Tests/
  OrqProtocolTests/ · OrqCoreTests/ · OrqTerminalTests/ · OrqDaemonKitTests/ · OrqIntegrationTests/
  Fixtures/fake-agent.sh
```

---

### Task 1: Repositório, pacote e tipos de protocolo

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/OrqProtocol/JSONValue.swift`, `Sources/OrqProtocol/Envelope.swift`
- Test: `Tests/OrqProtocolTests/EnvelopeTests.swift`

**Interfaces:**
- Produces:
```swift
public enum JSONValue: Codable, Sendable, Equatable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }

public enum ErrorCode: String, Codable, Sendable {
  case unauthorized, notFound, notConnected, notRunning, ambiguous, invalidArgs,
       timeout, deadlock, notMaestro, unsupportedVersion, daemonUnavailable, `internal`
}
public struct ProtocolError: Error, Codable, Sendable, Equatable { public var code: ErrorCode; public var message: String }

public struct Request: Codable, Sendable, Equatable {
  public var v: Int            // == Protocol.version
  public var id: String        // UUID string, ecoado na resposta
  public var terminalId: String?
  public var token: String?
  public var command: String
  public var args: [String: JSONValue]
  public var cwd: String?
}
public struct Response: Codable, Sendable, Equatable {
  public var v: Int; public var id: String; public var ok: Bool
  public var result: JSONValue?; public var error: ProtocolError?
}
public enum Protocol { public static let version = 1 }
```

- [ ] **Step 1:** `git init` na raiz; `.gitignore` com `.build/`, `.superpowers/`, `*.xcodeproj/xcuserdata/`, `.DS_Store`. `Package.swift` com os 4 targets de biblioteca, 2 executáveis e 5 targets de teste da File Structure; `platforms: [.macOS(.v15)]`, `swiftLanguageModes: [.v6]`.
- [ ] **Step 2: Write failing tests** em `EnvelopeTests.swift`:
  - `requestRoundTrips`: encode→decode de um `Request` com `args = ["target": .string("Reviewer"), "raw": .bool(true), "lines": .number(50)]` é igual ao original.
  - `jsonValueDecodesNested`: `{"a":[1,"x",null,{"b":false}]}` decodifica para `.object(["a": .array([.number(1), .string("x"), .null, .object(["b": .bool(false)])])])`.
  - `errorResponseShape`: `Response(v:1,id:"x",ok:false,result:nil,error:.init(code:.notConnected,message:"m"))` serializa com `"code":"notConnected"`.
- [ ] **Step 3:** Rodar `swift test --filter OrqProtocolTests` → FAIL (tipos inexistentes).
- [ ] **Step 4:** Implementar os tipos acima (JSONValue com `singleValueContainer`).
- [ ] **Step 5:** `swift test --filter OrqProtocolTests` → PASS.
- [ ] **Step 6:** Commit `feat(protocol): versioned request/response envelope`.

---

### Task 2: Tabela de comandos, parser de argv e schema MCP

**Files:**
- Create: `Sources/OrqProtocol/Commands.swift`, `ArgvParser.swift`, `MCPSchema.swift`
- Test: `Tests/OrqProtocolTests/CommandsTests.swift`

**Interfaces:**
- Consumes: `JSONValue`, `ProtocolError` (Task 1)
- Produces:
```swift
public struct ParamSpec: Sendable { public enum Kind: Sendable { case string, int, flag, rest }
  public var name: String; public var kind: Kind; public var positional: Bool; public var required: Bool; public var help: String }
public struct CommandSpec: Sendable {
  public var name: String; public var summary: String; public var params: [ParamSpec]
  public var timeoutSeconds: Double?      // nil = usa --timeout / padrão do comando
  public var maestroOnly: Bool; public var exposedToMCP: Bool
}
public enum Commands { public static let all: [CommandSpec]; public static func spec(_ name: String) -> CommandSpec? }
public enum ArgvParser { public static func parse(_ argv: [String]) throws(ProtocolError) -> (command: String, args: [String: JSONValue]) }
public enum MCPSchema { public static func tools() -> [JSONValue] }   // [{name, description, inputSchema}]
```
- Valores fixados em `Commands.all` (Fase 1A):
  - `list` — sem params; timeout 10.
  - `ask` — `target` (string, posicional, req), `prompt` (rest, req), `raw` (flag), `timeout` (int, segundos); timeout = valor de `--timeout` ou **1800**.
  - `check` — `target` (posicional, req), `lines` (int, padrão **200**); timeout 10.
  - `turn.completed` — `message` (string), `source` (string: `claude|codex|generic`); `exposedToMCP: false` (só hooks).
  - `admin.spawn` — `name`, `preset` (`shell|claude|codex|custom`), `command` (opcional), `cwd`, `maestro` (flag); `exposedToMCP: false`.
  - `admin.connect` — `a`, `b`; `admin.kill` — `target`; ambos `exposedToMCP: false`.

- [ ] **Step 1: Write failing tests:**
  - `parsesAskWithRestPrompt`: `["ask","Reviewer","revise","o","PR","--raw"]` → command `ask`, args `target="Reviewer"`, `prompt="revise o PR"`, `raw=true`.
  - `parsesCheckIntFlag`: `["check","Bob","--lines","50"]` → `lines=.number(50)`.
  - `rejectsUnknownCommand`: `["bogus"]` lança `ProtocolError(code:.invalidArgs, …)` com mensagem contendo `bogus`.
  - `rejectsMissingRequired`: `["ask"]` lança `.invalidArgs` mencionando `target`.
  - `mcpSchemaOmitsInternalCommands`: nomes em `MCPSchema.tools()` == `["list","ask","check"]`; o de `ask` tem `required` contendo `target` e `prompt`.
- [ ] **Step 2:** `swift test --filter CommandsTests` → FAIL.
- [ ] **Step 3:** Implementar. `ArgvParser`: primeiro token = comando; flags `--name` (flag sem valor; string/int com valor seguinte); posicionais na ordem; `rest` consome o restante não-flag juntando com espaço. MCP: `inputSchema` JSON Schema `type: object`, `int → integer`, `flag → boolean`, demais `string`.
- [ ] **Step 4:** `swift test --filter CommandsTests` → PASS.
- [ ] **Step 5:** Commit `feat(protocol): single command table drives CLI parser and MCP schema`.

---

### Task 3: Scrollback com teto de memória e spill em disco

**Files:**
- Create: `Sources/OrqTerminal/ScrollbackBuffer.swift`, `ANSI.swift`
- Test: `Tests/OrqTerminalTests/ScrollbackBufferTests.swift`

**Interfaces:**
- Produces:
```swift
public enum ANSI { public static func strip(_ s: String) -> String }   // remove CSI, OSC, ESC simples, \r isolado
public final class ScrollbackBuffer: @unchecked Sendable {   // acesso serializado por lock interno
  public init(memoryCapBytes: Int = 1_048_576, spillURL: URL?)
  public func append(_ data: Data)
  public var totalBytesWritten: Int { get }
  public var memoryBytes: Int { get }
  public func mark() -> Int                                   // = totalBytesWritten no momento
  public func text(since mark: Int) -> (text: String, truncated: Bool)   // ANSI removido
  public func tail(lines: Int) -> (text: String, truncated: Bool)
}
```
- Ring em memória com teto **1 MiB**; tudo que chega é anexado ao `spillURL` (se houver). `truncated` = o trecho pedido começa antes do que ainda está em memória.

- [ ] **Step 1: Write failing tests:**
  - `stripsAnsi`: `"\u{1B}[31mred\u{1B}[0m \u{1B}]0;title\u{07}ok"` → `"red ok"`.
  - `tailReturnsLastLines`: 5 linhas `l1…l5`, `tail(lines: 2).text == "l4\nl5"`, `truncated == false`.
  - `capsMemoryUnderFlood`: cap 64 KiB, anexar 10 MiB em blocos de 4 KiB → `memoryBytes <= 65_536`; `totalBytesWritten == 10_485_760`; arquivo de spill tem 10 485 760 bytes.
  - `textSinceMarkTruncatesWhenEvicted`: cap 1 KiB, `m = mark()`, anexar 4 KiB → `text(since: m).truncated == true`; anexar após novo mark 100 bytes → `truncated == false` e texto == os 100 bytes.
- [ ] **Step 2:** `swift test --filter ScrollbackBufferTests` → FAIL.
- [ ] **Step 3:** Implementar (ring de `Data` com offset base; `NSLock`; `FileHandle` para spill).
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(terminal): bounded scrollback with disk spill`.

---

### Task 4: Processo em PTY e injeção de prompt

**Files:**
- Create: `Sources/OrqTerminal/PTYProcess.swift`, `PromptInjector.swift`
- Test: `Tests/OrqTerminalTests/PTYProcessTests.swift`, `PromptInjectorTests.swift`

**Interfaces:**
- Consumes: `ScrollbackBuffer` (Task 3)
- Produces:
```swift
public struct LaunchSpec: Sendable { public var executable: String; public var arguments: [String]
  public var environment: [String: String]; public var cwd: String; public var cols: UInt16 = 120; public var rows: UInt16 = 40 }
public final class PTYProcess: @unchecked Sendable {
  public init(spec: LaunchSpec, scrollback: ScrollbackBuffer) throws
  public var pid: pid_t { get }
  public var isRunning: Bool { get }
  public var lastOutputAt: ContinuousClock.Instant? { get }
  public var onOutput: (@Sendable (Data) -> Void)?           // para a UI no plano 1B
  public var onExit: (@Sendable (Int32) -> Void)?
  public func write(_ data: Data) throws
  public func resize(cols: UInt16, rows: UInt16)
  public func terminate()                                    // SIGHUP, depois SIGKILL após 2 s
}
public enum PromptInjector {
  public static func sanitize(_ prompt: String) -> String
  public static func payload(_ prompt: String, raw: Bool) -> Data   // raw=false: ESC[200~ + sanitize + ESC[201~ + "\r"
}
```
- `sanitize`: remove `ESC[200~`, `ESC[201~` e todo C0 exceto `\n` e `\t`; preserva Unicode.
- Leitura do master via `DispatchSourceRead` numa fila serial própria do processo; `waitpid` via `DispatchSourceProcess`.

- [ ] **Step 1: Write failing tests:**
  - `sanitizesPasteTerminator`: `sanitize("a\u{1B}[201~b\u{03}c\nd ✓")` == `"ab" + "c\nd ✓"`.
  - `payloadWrapsBracketedPaste`: `payload("hi", raw:false)` == bytes de `"\u{1B}[200~hi\u{1B}[201~\r"`; `payload("x\\n", raw:true)` == `"x\n"` interpretando `\n`, `\t`, `\e`, `\xNN`.
  - `echoesThroughPTY`: lança `/bin/cat`, escreve `"ping\n"`, em até 2 s o scrollback contém `ping`.
  - `reportsExitCode`: lança `/bin/sh -c "exit 7"`, `onExit` recebe `7` em até 2 s; `isRunning == false`.
  - `passesEnvironmentAndCwd`: `/bin/sh -c 'echo $ORQ_TEST:$(pwd)'` com env `ORQ_TEST=ok`, cwd temporário → scrollback contém `ok:<cwd>`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implementar com `forkpty` + `execve` (env explícito, sem herdar além do passado), `TIOCSWINSZ` no resize.
- [ ] **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(terminal): PTY process and safe prompt injection`.

---

### Task 5: Workspace, persistência e grafo de conexões

**Files:**
- Create: `Sources/OrqCore/Paths.swift`, `Workspace.swift`, `WorkspaceStore.swift`, `ConnectionGraph.swift`
- Test: `Tests/OrqCoreTests/ConnectionGraphTests.swift`, `WorkspaceStoreTests.swift`

**Interfaces:**
- Produces:
```swift
public struct Paths: Sendable { public var root: URL           // padrão ~/Library/Application Support/Orq
  public init(root: URL = Paths.defaultRoot)
  public var runDir: URL      // root/run  (0700)
  public var socket: URL      // runDir/orqd.sock
  public var adminTokenFile: URL   // root/admin.token (0600)
  public func workspaceDir(_ id: UUID) -> URL  // root/workspaces/<id>
}
public enum Preset: String, Codable, Sendable { case shell, claude, codex, custom }
public struct TerminalRecord: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID; public var name: String; public var preset: Preset; public var command: String?
  public var cwd: String; public var isMaestro: Bool }
public struct Connection: Codable, Sendable, Equatable { public var a: UUID; public var b: UUID }
public struct Workspace: Codable, Sendable, Equatable { public var schemaVersion: Int = 1; public var id: UUID; public var name: String
  public var terminals: [TerminalRecord]; public var connections: [Connection] }
public enum ConnectionGraph {
  public static func reachable(from: UUID, in ws: Workspace) -> [TerminalRecord]   // Maestro: todos menos ele; demais: conectados
  public static func resolve(name: String, from: UUID, in ws: Workspace) throws(ProtocolError) -> TerminalRecord
}
public actor WorkspaceStore { public init(paths: Paths)
  public func load(_ id: UUID) throws -> Workspace; public func save(_ ws: Workspace) throws }   // escrita atômica
```
- ~~Maestro alcança qualquer terminal do workspace~~ — **revogado pelo usuário em 2026-10-19:** Maestro segue a mesma regra de corda que os demais.

- [ ] **Step 1: Write failing tests:**
  - `resolvesOnlyConnected`: A–B conectados, C solto; `resolve("B", from:A)` ok; `resolve("C", from:A)` lança `.notConnected` com mensagem contendo `C`.
  - `resolveUnknownName`: `resolve("Z", from:A)` → `.notFound`.
  - `resolveAmbiguous`: dois terminais chamados `B` conectados a A → `.ambiguous`.
  - `maestroReachesAll`: A maestro sem conexões; `reachable(from:A)` contém B e C.
  - `nameMatchIsCaseInsensitive`: `resolve("reviewer", …)` encontra `Reviewer`.
  - `storeRoundTripsAtomically`: save/load igual; arquivo é `workspaceDir/workspace.json`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(core): workspace model, store and connection gating`.

---

### Task 6: Socket Unix (servidor e cliente)

**Files:**
- Create: `Sources/OrqDaemonKit/UnixSocket.swift`
- Test: `Tests/OrqDaemonKitTests/UnixSocketTests.swift`

**Interfaces:**
- Consumes: `Request`, `Response` (Task 1), `Paths` (Task 5)
- Produces:
```swift
public final class UnixSocketServer: @unchecked Sendable {
  public init(path: URL, handler: @escaping @Sendable (Request) async -> Response)
  public func start() throws          // cria dir 0700; remove socket órfão; bind/listen; accept via DispatchSource
  public func stop()
}
public enum UnixSocketClient {
  public static func send(_ req: Request, to path: URL, timeoutSeconds: Double?) async throws(ProtocolError) -> Response
}
```
- Framing: cliente escreve **uma linha JSON** (`\n`), servidor responde **uma linha JSON** e fecha. Limite de requisição **4 MiB** → `invalidArgs` "request too large".
- Socket órfão = arquivo existe mas `connect` falha com `ECONNREFUSED` → remover. Se `connect` funciona → `start()` lança "daemon already running".
- Cliente: socket inexistente/recusado → `ProtocolError(.daemonUnavailable, "daemon não está rodando (orqd)")`; timeout → `.timeout`.

- [ ] **Step 1: Write failing tests:**
  - `roundTripsOneRequest`: servidor eco (`result = .string(req.command)`) responde `ok=true`, `id` igual.
  - `removesStaleSocket`: criar arquivo socket órfão (bind e fechar sem unlink) → `start()` sucede.
  - `refusesSecondDaemon`: segundo `start()` no mesmo path lança.
  - `clientReportsDaemonUnavailable`: path inexistente → `.daemonUnavailable`.
  - `clientTimesOut`: handler dorme 2 s, timeout 0.3 → `.timeout` em < 1 s.
  - `serverHandlesConcurrentClients`: 50 envios concorrentes → 50 respostas com ids corretos.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(daemon): unix socket transport with stale-socket recovery`.

---

### Task 7: Auth, registro de terminais, roteador e daemon (`list`, `admin.*`)

**Files:**
- Create: `Sources/OrqDaemonKit/AuthRegistry.swift`, `TerminalRegistry.swift`, `CommandRouter.swift`, `Daemon.swift`, `Sources/orqd/main.swift`
- Test: `Tests/OrqDaemonKitTests/RouterTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces:
```swift
public actor AuthRegistry {
  public func issue(for terminal: UUID) -> String          // 32 bytes SecRandomCopyBytes → hex
  public func verify(terminal: UUID, token: String) -> Bool // tempo constante
  public func revoke(_ terminal: UUID)
  public let adminToken: String                             // gravado em Paths.adminTokenFile 0600 no boot
}
public actor TerminalRegistry {
  public func spawn(_ rec: TerminalRecord, launch: LaunchSpec) throws -> PTYProcess
  public func process(_ id: UUID) -> PTYProcess?
  public func scrollback(_ id: UUID) -> ScrollbackBuffer?
  public func kill(_ id: UUID)
}
public struct DaemonConfig: Sendable { public var paths: Paths; public var orqExecutable: URL; public var workspaceId: UUID
  public var idleQuietSeconds: Double = 2.0; public var memoryCapBytes: Int = 1_048_576 }
public final class Daemon: Sendable { public init(config: DaemonConfig) throws; public func start() async throws; public func stop() async }
```
- Env injetado em todo terminal: `ORQ_SOCKET`, `ORQ_TERMINAL_ID`, `ORQ_TOKEN`, `ORQ_TERMINAL_NAME`, `ORQ_WORKSPACE_ID`, `TERM=xterm-256color`, `TERM_PROGRAM=Orq`, `PATH` = dir do `orq` + `PATH` do daemon.
- Roteamento: `v != 1` → `unsupportedVersion`; `admin.*` exige `token == adminToken`; demais exigem `terminalId`+`token` válidos → senão `unauthorized`. `list` → `.array` de `{name, preset, running, isMaestro}` alcançáveis.
- `orqd` main: `--root <dir>` (padrão `Paths.defaultRoot`), `--workspace <uuid>` (cria se não existir); trata SIGTERM chamando `stop()` (mata PTYs, remove socket).

- [ ] **Step 1: Write failing tests** (daemon em processo, `Paths(root: tmp)`):
  - `rejectsWrongVersion` → `.unsupportedVersion`.
  - `rejectsBadToken`: terminal válido com token errado → `.unauthorized`.
  - `adminSpawnAndList`: `admin.spawn` A (shell) e B, `admin.connect A B`; `list` como A retorna só `B` com `running=true`.
  - `injectsEnvironment`: spawn com preset `custom`, command `env`; scrollback contém `ORQ_TERMINAL_ID=<id>` e `TERM_PROGRAM=Orq` e **não** contém o token de outro terminal.
  - `adminTokenFileIsPrivate`: permissões de `admin.token` == `0o600`; `run/` == `0o700`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(daemon): token auth, terminal registry and list`.

---

### Task 8: `ask` / `check` / `turn.completed`

**Files:**
- Create: `Sources/OrqDaemonKit/AskCoordinator.swift`; Modify: `CommandRouter.swift`
- Create: `Tests/Fixtures/fake-agent.sh`
- Test: `Tests/OrqDaemonKitTests/AskTests.swift`

**Interfaces:**
- Consumes: `TerminalRegistry`, `ScrollbackBuffer.mark/text(since:)`, `PromptInjector`, `ConnectionGraph.resolve`.
- Produces:
```swift
public actor AskCoordinator {
  public func ask(from: UUID, to: UUID, prompt: String, raw: Bool, timeout: Duration) async throws(ProtocolError) -> AskResult
  public func turnCompleted(terminal: UUID, message: String?)       // chamado por turn.completed
  public func processExited(_ terminal: UUID)
}
public struct AskResult: Sendable, Equatable { public var output: String; public var source: Source; public var truncated: Bool
  public enum Source: String, Sendable { case hook, idle } }
```
Resultado de `ask` serializado como `{output, source, truncated}`; `check` → `{output, truncated}` de `tail(lines:)`.

Algoritmo do `ask` (o que os testes não determinam sozinhos):
1. Detecção de deadlock: grafo de asks pendentes (`from → to`); se `to` alcança `from` → `.deadlock` imediatamente.
2. Fila **FIFO por alvo**: um ask por vez por terminal alvo; os demais esperam (contando no timeout).
3. `m = scrollback.mark()`; escreve `PromptInjector.payload`.
4. Aguarda o primeiro de: (a) `turnCompleted(to, message)` → `output = message ?? text(since: m)`, `source = .hook`; (b) **fallback ocioso**: houve saída após a injeção e `lastOutputAt` está quieto há `idleQuietSeconds` (2.0 s) **e o alvo não tem hook** (preset `shell`/`custom`) → `text(since: m)`, `source = .idle`; (c) `processExited` → `.notRunning`; (d) timeout → `.timeout`.
5. Presets `claude`/`codex` usam **só** hook (sem fallback ocioso — ociosidade mente em TUIs que pensam em silêncio) **[call]**.

`fake-agent.sh`: lê linhas do stdin; para cada linha `X`, imprime `thinking...`, dorme 0.5 s, imprime `answer:X`, e se `ORQ_FAKE_HOOK=1` imprime o marcador `<<ORQ_FAKE_STOP:answer:X>>`. Nesta task (antes do binário `orq` existir) o teste observa o marcador no scrollback e chama `turnCompleted` direto; a partir da Task 10 o fake-agent passa a executar `orq hook generic-stop --message "answer:X"` quando `ORQ_FAKE_HOOK=cli`.

- [ ] **Step 1: Write failing tests:**
  - `askViaHook`: alvo `fake-agent` com hook; `ask(A→B,"hello")` → `output == "answer:hello"`, `source == .hook`.
  - `askViaIdleFallback`: alvo `shell` rodando `fake-agent` sem hook → `output` contém `answer:hello`, `source == .idle`.
  - `askRejectsUnconnected`: A→C sem corda → `.notConnected`.
  - `askDetectsDeadlock`: A ask B pendente (B nunca responde); B ask A → `.deadlock` em < 100 ms.
  - `askTimesOut`: alvo `sleep 999` preset `claude` (sem hook disparado), timeout 1 s → `.timeout` em ≤ 1.5 s.
  - `askFailsFastWhenTargetExits`: alvo `sh -c "read x; exit 0"` preset `claude` → `.notRunning` em < 1 s.
  - `asksToSameTargetAreSerialized`: 3 asks concorrentes de A,C,D para B → 3 respostas corretas, cada `output` corresponde ao próprio prompt.
  - `askMarksTruncated`: alvo imprime 3 MiB após prompt, memory cap 1 MiB, fallback ocioso → `truncated == true`.
  - `checkReturnsTail`: `check B --lines 1` → última linha.
- [ ] **Step 2:** FAIL. **Step 3:** implementar; ligar `onExit` → `processExited`. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(daemon): ask/check with hook completion, idle fallback, FIFO and deadlock detection`.

---

### Task 9: Lançamento por preset com hooks por flag

**Files:**
- Create: `Sources/OrqDaemonKit/AgentLaunch.swift`, `Sources/OrqProtocol/HookPayload.swift`, `Sources/orq/HookCommands.swift`
- Test: `Tests/OrqDaemonKitTests/AgentLaunchTests.swift`, `Tests/OrqProtocolTests/HookParsingTests.swift`

**Interfaces:**
- Produces:
```swift
public enum AgentLaunch {
  public static func launchSpec(for rec: TerminalRecord, env: [String: String], hooksDir: URL, orq: URL, shell: String) throws -> LaunchSpec
}
public enum HookPayload {       // em OrqProtocol, usado pelo `orq hook`
  public static func claudeStopMessage(stdinJSON: Data) -> String?   // usa "last_assistant_message" se existir; senão lê transcript_path (JSONL) e pega o texto da última mensagem role=assistant
  public static func codexNotifyMessage(argJSON: String) -> String?  // type == "agent-turn-complete" → "last-assistant-message"
}
```
- `claude`: shell `-lc` rodando `claude --settings <hooksDir>/<terminalId>.claude.json`; arquivo contém `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"<orq> hook claude-stop"}]}]}}`.
- `codex`: `codex -c 'notify=["<orq>","hook","codex-notify"]'`. **Codex não está instalado nesta máquina** → validar manualmente quando estiver (Step 6).
- `shell`: `$SHELL -l`; `custom`: `$SHELL -lc <command>`.
- `orq hook claude-stop` (stdin) / `orq hook codex-notify <json>` / `orq hook generic-stop --message <m>` → enviam `turn.completed` com `ORQ_TERMINAL_ID`/`ORQ_TOKEN` do ambiente; **sempre exit 0** (hook nunca pode quebrar o agente); erros vão para `~/Library/Logs/Orq/hooks.log`.

- [ ] **Step 1: Write failing tests:**
  - `claudeSpecUsesSettingsFlag`: argumentos contêm `--settings` e o arquivo gerado decodifica com `hooks.Stop[0].hooks[0].command` terminando em `hook claude-stop`.
  - `codexSpecUsesNotifyOverride`: argumentos contêm `-c` e `notify=["…","hook","codex-notify"]`.
  - `noGlobalSettingsTouched`: após gerar specs com `HOME` temporário, `~/.claude/settings.json` e `~/.codex/config.toml` não existem.
  - `parsesClaudeStopFromField` e `parsesClaudeStopFromTranscript` (fixture JSONL com 2 mensagens assistant → retorna a última).
  - `parsesCodexNotify`: `{"type":"agent-turn-complete","last-assistant-message":"done"}` → `"done"`; tipo diferente → `nil`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(daemon): per-preset launch with flag-scoped hooks`.
- [ ] **Step 6 (manual):** com `orqd` rodando, `admin.spawn` de um `claude` real e um shell conectados; do shell, `orq ask Claude "responda só OK"` → retorna `OK` com `source: hook`. Registrar resultado no PR. Repetir com `codex` quando instalado.

---

### Task 10: CLI `orq` e servidor `orq mcp`

**Files:**
- Create: `Sources/orq/main.swift`, `Sources/orq/MCPServer.swift`
- Test: `Tests/OrqIntegrationTests/CLITests.swift`, `MCPTests.swift`

**Interfaces:**
- Consumes: `ArgvParser`, `UnixSocketClient`, `MCPSchema`, `Commands.spec(_:).timeoutSeconds`.
- Produces: binário `orq`:
  - `orq <comando> …` → monta `Request` (ids de `ORQ_TERMINAL_ID`/`ORQ_TOKEN`, `cwd` atual) e imprime: sucesso → `output` em texto (ou JSON com `--json`); erro → `orq: <message>` no stderr.
  - Exit codes: **0** ok, **1** erro do comando, **2** uso inválido, **3** `daemonUnavailable`.
  - `orq admin <spawn|connect|kill> …` lê `admin.token`.
  - `orq mcp`: JSON-RPC 2.0 por stdio, uma mensagem por linha; implementa `initialize` (protocolVersion `2025-06-18`, `capabilities.tools`), `notifications/initialized`, `tools/list` (de `MCPSchema.tools()`), `tools/call` (repassa ao daemon; erro do daemon → `isError: true` com a mensagem).

- [ ] **Step 1: Write failing tests** (executam o binário construído contra um daemon em processo):
  - `cliListPrintsNames`: exit 0, stdout contém `B`.
  - `cliErrorGoesToStderr`: `orq ask Zed oi` → exit 1, stderr começa com `orq: `.
  - `cliUsageExit2`: `orq ask` → exit 2.
  - `cliReportsDaemonDown`: `ORQ_SOCKET` apontando para path inexistente → exit 3, stderr contém `orqd`.
  - `mcpListsTools`: enviar `initialize` + `tools/list` → nomes `list, ask, check`.
  - `mcpCallAsk`: `tools/call ask {target:"B",prompt:"hi"}` com fake-agent → conteúdo contém `answer:hi`.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(cli): orq CLI and stdio MCP server over the daemon`.

---

### Task 11: Teste de confiabilidade e memória (soak)

**Files:**
- Test: `Tests/OrqIntegrationTests/SoakTests.swift`

**Interfaces:**
- Consumes: tudo acima.

- [ ] **Step 1: Write test** `soakTwentyAgents` (tag `.soak`, roda em CI noturna e localmente com `swift test --filter Soak`):
  - 20 terminais `fake-agent` com `ORQ_FAKE_HOOK=cli` (hook real pelo binário `orq`), todos conectados a um Maestro.
  - 200 asks (10 rodadas × 20, concorrentes por rodada).
  - Asserts: **taxa de sucesso 100%**, latência p95 < 2 s (fake-agent dorme 0.5 s), **RSS do daemon** (via `proc_pid_rusage`) após a rodada 10 ≤ RSS após a rodada 2 + **20 MiB** (detector de leak), `memoryBytes` de cada scrollback ≤ 1 MiB.
- [ ] **Step 2:** Rodar; se falhar, corrigir a causa no componente dono (não afrouxar limites sem registrar o motivo no commit).
- [ ] **Step 3:** Commit `test: soak test for ask reliability and daemon memory`.

---

## Self-review (feito)

- **Cobertura do spec para 1A:** daemon separado (§4) T7; protocolo versionado/erros/timeouts (§4, §9) T1–T2, T6, T10; auth por token + 0700 (§4) T6–T7; CLI + MCP mesma superfície (§4) T2, T10; resposta por hooks com fallback (§9) T8–T9; bracketed paste (§9) T4; RAM com teto/spill (§10) T3, T11; testes de desempenho contínuos (§10) T11; convivência com Maestri (§3) Global Constraints + T9 `noGlobalSettingsTouched`. Canvas, Maestro completo, andares, plug-ins, memória, navegador, uso: planos 1B–1E.
- **Tipos consistentes:** `TerminalRecord`, `Preset`, `LaunchSpec`, `AskResult`, `ProtocolError` usados com os mesmos nomes em T4–T10.
