# Plano 1C — Maestro, andares e uso dos agentes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um terminal Maestro que recruta, dispensa, conecta e notifica dentro do alcance das suas cordas; andares (git worktree isolado + land de volta) criados pelo Maestro ou pelo app; e um painel de uso de plano por CLI de agente.

**Architecture:** O Maestro não ganha token de admin. A "credencial" dele é o token do próprio terminal somado a `isMaestro`, flag que só o admin (app/usuário) define. Comandos `maestroOnly` exigem esse par, e o alcance vem sempre de `ConnectionGraph.reachable`. Andares vivem no `workspace.json` (schema 2) e são operados por um `FloorManager` que roda `git` fora do pool cooperativo. O uso dos agentes vem de provedores declarativos (JSON) executados pelo daemon com timeout, teto e cache. O app ganha seletor de andar, ações de land e um popover de uso; as docas ficam para o 1D.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, `git` (CLI do sistema), `gh` (opcional, só para land em modo PR), SwiftUI + AppKit. Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (§2 metas, §4, §5 Maestro/andares/uso, §8.7, §10). Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Base: `main` em `c7d5399` (1A + 1B). Referência de comportamento: a análise de referência (local, não publicada) §3.3, §3.6.

## Global Constraints

- macOS **15.0**, Swift 6.2, modo Swift 6 (concorrência estrita). Nenhuma dependência nova.
- **Cordas são a única permissão, inclusive para o Maestro** (decisão do usuário 2026-10-19). Todo alvo de comando do Maestro sai de `ConnectionGraph.reachable(from: maestro)`. Recrutar cria a corda automaticamente. Vários Maestros ficam isolados salvo corda explícita.
- Comandos de admin (`admin.*`, `ui.*`) continuam recusados vindos de terminais gerenciados (filtro de ancestralidade do 1A). O Maestro **nunca** usa o admin token.
- Nada sai da máquina sem pedido explícito do usuário: o land em modo `pr` (push + `gh pr create`) é **só admin** (app/usuário), nunca Maestro.
- `git` e provedores de uso rodam fora da main thread e fora do pool cooperativo (GCD + continuation), com timeout (`git` 120 s, provedor 30 s) e saída limitada a **1 MiB** por stream; truncou → erro/flag explícito, nunca em silêncio.
- Protocolo `v: 1` (só comandos e eventos novos; compatível). `workspace.json` passa a `schemaVersion: 2` e ainda lê arquivos v1.
- Nomes: env `ORQ_*`, branch de andar `orq/<nome>`, pasta `.orq/floors/<nome>`; nada com prefixo `maestri`. Clean-room.
- Testes usam `/bin/sh` e repositórios git temporários. Falhas instáveis conhecidas na suíte completa: `AskTests` (1 de 5 rodadas após o merge do 1B). Se uma falhar, rode-a isolada e registre.

## Review Focus

1. **Maestro tenta alcançar um terminal sem corda** (`connect a b` com `b` fora do alcance, `dismiss x`, `recruit` com nome já existente fora do alcance) → `notConnected`/`invalidArgs`, nada muda. Testes: Task 2 `connectCannotExtendReach`, `dismissNeedsCord`, `parallelMaestrosAreIsolated`.
2. **Land com o repositório principal sujo ou em outro branch** → erro tipado, nenhum arquivo nem branch alterado. Teste: Task 3 `landRefusesDirtyGround`.
3. **Land com conflito** → merge/rebase abortado, repositório limpo, resposta lista os arquivos em conflito. Teste: Task 3 `landConflictAbortsCleanly`.
4. **Nome de andar malicioso** (`../x`, `a/b`, espaço, 200 chars) → recusado antes de qualquer `git`. Teste: Task 3 `floorNameIsValidated`.
5. **Provedor de uso trava ou cospe lixo/MBs** → timeout de 30 s / teto de 1 MiB, erro na janela daquele provedor, os outros não são afetados. Teste: Task 5 `hungProviderTimesOutAlone`.

---

## File Structure

```
Sources/OrqCore/Workspace.swift          (+ Floor, FloorStatus, TerminalRecord.floorId, Workspace.floors, schema 2)
Sources/OrqCore/StreamFrames.swift       (+ WorkspaceEvent .floor/.floorRemoved/.notify; snapshot.floors)
Sources/OrqCore/Usage.swift              UsageProvider, UsageReport, JSONPointer
Sources/OrqProtocol/Commands.swift       (+ recruit, dismiss, connect, disconnect, notify, floor.*, ui.usage; admin.spawn --floor)
Sources/OrqDaemonKit/CommandRouter.swift (+ principal, maestroOnly, roteamento dos comandos novos)
Sources/OrqDaemonKit/MaestroCommands.swift   recruit/dismiss/connect/disconnect/notify (extension do router)
Sources/OrqDaemonKit/GitRunner.swift     git fora do pool, timeout, teto
Sources/OrqDaemonKit/FloorManager.swift  create/land/delete sobre um repo (sem estado de workspace)
Sources/OrqDaemonKit/FloorCommands.swift floor.* no router (extension)
Sources/OrqDaemonKit/UsageService.swift  carrega provedores, executa, cache
Sources/orq/MCPServer.swift              (+ ferramentas Maestro só com ORQ_MAESTRO=1)
Sources/OrqClient/DaemonClient.swift     (+ floors, onNotify, chamadas floor.*, usage())
Sources/OrqApp/FloorBar.swift            seletor de andar + criar/land/excluir
Sources/OrqApp/UsagePopover.swift        anéis/barras de uso
Resources/usage-providers/*.json         provedores padrão (copiados para <root>/usage/providers na 1ª execução)
Tests/OrqCoreTests/FloorModelTests.swift, UsageModelTests.swift
Tests/OrqDaemonKitTests/MaestroTests.swift, FloorManagerTests.swift, FloorCommandTests.swift, UsageServiceTests.swift
```

---

### Task 1: Modelo de andares, schema 2 e eventos

**Files:** Modify `Sources/OrqCore/Workspace.swift`, `Sources/OrqCore/StreamFrames.swift`; Test `Tests/OrqCoreTests/FloorModelTests.swift`

**Interfaces:**
- Produces:
```swift
public enum FloorStatus: String, Codable, Sendable { case working, blocked, review, done }
public enum LandMode: String, Codable, Sendable { case merge, squash, rebase, pr }
public struct Floor: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID; public var name: String
  public var repoRoot: String      // toplevel do repo principal (ground)
  public var path: String          // <repoRoot>/.orq/floors/<name>
  public var branch: String        // "orq/<name>"
  public var baseBranch: String    // branch do ground na criação
  public var status: FloorStatus   // começa .working
  public var createdBy: UUID?      // terminal Maestro criador; nil = app
  public var landedAt: Date?
}
TerminalRecord.floorId: UUID?      // nil = ground
Workspace.floors: [Floor]; Workspace.schemaVersion = 2
WorkspaceEvent: .floor(Floor) (upsert), .floorRemoved(UUID), .notify(UUID, message: String)
WorkspaceSnapshot.floors: [Floor]
```

- [ ] **Step 1: Write failing tests:**
  - `decodesSchemaV1Workspace`: o JSON v1 (sem `floors`, sem `floorId`) decodifica com `floors == []`, `floorId == nil`; re-encode grava `schemaVersion: 2`.
  - `floorEventsRoundTrip`: `.floor`, `.floorRemoved`, `.notify` codificam/decodificam iguais (chaves `t`: `"floor"`, `"floorRemoved"`, `"notify"`).
  - `snapshotCarriesFloors`.
- [ ] **Step 2–4:** RED → `decodeIfPresent` com defaults para os campos novos → GREEN.
- [ ] **Step 5:** Commit `feat(core): floors model, workspace schema 2, floor and notify events`.

---

### Task 2: Credencial do Maestro e comandos Maestro

**Files:** Modify `Sources/OrqProtocol/Commands.swift`, `Sources/OrqDaemonKit/CommandRouter.swift`, `Sources/OrqDaemonKit/AskCoordinator.swift`, `Sources/orq/MCPServer.swift`; Create `Sources/OrqDaemonKit/MaestroCommands.swift`; Test `Tests/OrqDaemonKitTests/MaestroTests.swift`

**Interfaces:**
- Consumes: `ConnectionGraph.reachable/resolve`, `TerminalRecord.floorId` (Task 1), `launch(_:)` e `discard(_:)` do router.
- Produces (todos `maestroOnly: true`, autenticados pelo token do terminal; quem chama precisa ter `isMaestro == true`, senão `ProtocolError(.notMaestro, "'<cmd>' is Maestro-only")`):

| Comando | Params | Regra |
|---|---|---|
| `recruit` | `name` (pos., obr.), `preset` (obr.), `command`, `cwd`, `floor`, `prompt` (rest) | Nome não pode existir no workspace (`invalidArgs` "already exists"). Recruta nunca é Maestro. `cwd` padrão = `cwd` do Maestro; com `floor`, padrão = `floor.path` e `floorId` = o andar; sem `floor`, herda o `floorId` do Maestro. Cria a corda Maestro↔recruta e emite `.connected`. `prompt` presente → injeta sem esperar resposta (`AskCoordinator.inject`). Retorna `{id, name}`. |
| `dismiss` | `target` | `target` resolvido via `ConnectionGraph.resolve` a partir do Maestro; alvo Maestro → `invalidArgs`. Mesmo efeito de `admin.kill`. |
| `connect` | `a`, `b` | **Os dois** precisam estar em `reachable(maestro)` (o próprio Maestro não conta: ligar-se a um estranho ampliaria o alcance). |
| `disconnect` | `a`, `b` | `a`, `b` ∈ `reachable(maestro) ∪ {maestro}`. |
| `notify` | `message` (rest, obr., ≤ 2000 chars) | Emite `.notify(maestroId, message)`. |

- `AskCoordinator.inject(to: UUID, prompt: String) async throws(ProtocolError)`: mesma porta de prontidão e mesma fila FIFO do `ask`, mas não espera o fim do turno.
- Env do terminal Maestro: `ORQ_MAESTRO=1`. `orq mcp` só lista as ferramentas `maestroOnly` com `ORQ_MAESTRO=1`; o daemon continua sendo quem decide.
- Refatoração: `admin.kill` e `dismiss` compartilham `remove(_ t: TerminalRecord)`; `admin.connect` e `connect` compartilham `cord(_:_:)` / `uncord(_:_:)`.

- [ ] **Step 1: Write failing tests** (daemon real, `/bin/sh`):
  - `nonMaestroIsRefused`: terminal comum chama `recruit` → `.notMaestro`.
  - `recruitCreatesCordAndInherits`: o recruta aparece no `list` do Maestro, `isMaestro == false`, `cwd` e `floorId` herdados.
  - `recruitPromptIsInjected`: `recruit w --preset shell echo hi-from-maestro` → o scrollback de `w` contém `hi-from-maestro`.
  - `connectCannotExtendReach`: M ligado a A, não a B → `connect A B` e `connect M B` → `.notConnected`, e as cordas não mudam.
  - `dismissNeedsCord`: `dismiss X` sem corda → `.notConnected`; com corda → X removido, `.removed` emitido.
  - `parallelMaestrosAreIsolated`: M1 e M2 com recrutas próprios; M1 não lista, não dispensa nem conecta os recrutas de M2.
  - `adminTokenFromMaestroStillRefused`: um processo dentro do terminal Maestro com o admin token → `.unauthorized` (regressão do 1A).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(daemon): Maestro commands scoped by cords`.

---

### Task 3: GitRunner e FloorManager

**Files:** Create `Sources/OrqDaemonKit/GitRunner.swift`, `Sources/OrqDaemonKit/FloorManager.swift`; Test `Tests/OrqDaemonKitTests/FloorManagerTests.swift`

**Interfaces:**
```swift
struct GitResult: Sendable { var status: Int32; var stdout: String; var stderr: String; var truncated: Bool }
enum GitRunner {   // Process("/usr/bin/git") numa fila GCD + continuation; mata no timeout; 1 MiB por stream
  static func run(_ args: [String], in dir: URL, timeout: Duration = .seconds(120),
                  executable: URL = URL(fileURLWithPath: "/usr/bin/git")) async throws(ProtocolError) -> GitResult   // executable: só para teste
}
enum FloorManager {   // puro sobre o repo; sem estado de workspace
  static func validate(name: String) throws(ProtocolError)          // ^[a-z0-9][a-z0-9-]{0,39}$
  static func repoRoot(of dir: URL) async throws(ProtocolError) -> URL   // git rev-parse --show-toplevel do ground (via --git-common-dir se dir for um worktree)
  static func create(name: String, repoRoot: URL, createdBy: UUID?) async throws(ProtocolError) -> Floor
  static func land(_ f: Floor, mode: LandMode, message: String?) async throws(ProtocolError) -> LandResult
  static func delete(_ f: Floor, force: Bool) async throws(ProtocolError)
}
struct LandResult: Codable, Sendable { var mode: LandMode; var commit: String?; var prURL: String?; var conflicts: [String] }
```
- **create:** `git worktree add -b orq/<name> <repo>/.orq/floors/<name> <baseBranch>`. `baseBranch` = branch atual do ground (HEAD destacado → `invalidArgs`). Acrescenta `.orq/floors/` a `<git-common-dir>/info/exclude` sem duplicar (não toca no `.gitignore` do usuário). Nome ou pasta já existentes → `invalidArgs`.
- **land** (pré-condições, todas antes de mudar qualquer coisa): worktree do andar limpo (`git status --porcelain` vazio, senão `invalidArgs` "floor has uncommitted changes"); ground limpo e com `baseBranch` em checkout (senão `invalidArgs` com o motivo).
  - `merge`: no ground, `git merge --no-ff orq/<name> -m "<message ou 'Land floor <name>'>"`.
  - `squash`: `git merge --squash orq/<name>` + `git commit -m …`.
  - `rebase`: no andar, `git rebase <baseBranch>`; depois, no ground, `git merge --ff-only orq/<name>`.
  - `pr`: `git push -u origin orq/<name>` + `gh pr create --base <base> --head orq/<name> --fill`; sem `gh` ou sem remote → `invalidArgs`.
  - Conflito: `git merge --abort` / `git rebase --abort`; retorna `LandResult.conflicts` (de `git diff --name-only --diff-filter=U`, capturado antes do abort) e erro `invalidArgs` "land conflicts: …". O repo fica como antes.
  - Sucesso: `status = .done`, `landedAt = now`.
- **delete:** `git worktree remove [--force] <path>`. Branch: `git branch -d` (`-D` com `force`). Andar sujo sem `force` → erro.

- [ ] **Step 1: Write failing tests** (repo temporário com `git init -b main`, commit inicial, `user.name`/`email` locais):
  - `floorNameIsValidated`: `../x`, `a/b`, `A`, `a b`, 41 chars → `.invalidArgs`; nenhum `git` executado (pasta `.orq` não existe).
  - `createMakesWorktreeAndExclude`: pasta e branch `orq/feat` existem; `info/exclude` contém `.orq/floors/` exatamente uma vez após dois creates.
  - `landMergeSquashRebase`: um caso parametrizado por modo (`merge`, `squash`, `rebase`) → o commit do andar chega ao `main`; `merge` gera commit de merge, `squash` gera um commit sem segundo pai, `rebase` deixa histórico linear.
  - `landRefusesDirtyGround`: ground com arquivo modificado → erro; `git rev-parse main` inalterado.
  - `landRefusesDirtyFloor`.
  - `landConflictAbortsCleanly`: mesma linha editada nos dois lados → erro com `conflicts == ["f.txt"]`; `git status --porcelain` vazio no ground e sem `MERGE_HEAD`.
  - `gitTimeoutKills`: `GitRunner.run(["60"], in: tmp, timeout: .seconds(1), executable: /bin/sleep)` → `.timeout` em < 3 s e o processo não existe mais.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(daemon): git runner and floor manager (create, land, delete)`.

---

### Task 4: Comandos `floor.*` e terminais em andares

**Files:** Create `Sources/OrqDaemonKit/FloorCommands.swift`; Modify `Sources/OrqProtocol/Commands.swift`, `Sources/OrqDaemonKit/CommandRouter.swift`, `Sources/OrqDaemonKit/MaestroCommands.swift`; Test `Tests/OrqDaemonKitTests/FloorCommandTests.swift`

**Interfaces:**
- Consumes: `FloorManager` (Task 3), modelo (Task 1), `recruit` (Task 2).
- **Principal:** `floor.*` aceita o admin token (com o filtro de ancestralidade de sempre) **ou** um token de terminal. O `maestroOnly` não se aplica aqui; as regras são por comando:

| Comando | Params | Admin | Terminal |
|---|---|---|---|
| `floor.create` | `name`, `repo` (admin: obrigatório) | sim | só Maestro; repo = `repoRoot` do `cwd` do Maestro; `createdBy` = Maestro |
| `floor.list` | — | todos | todos (leitura) |
| `floor.status` | `name`, `status` | sim | Maestro criador, ou terminal com `floorId` == andar |
| `floor.land` | `name`, `mode` (padrão `merge`), `message` | qualquer modo | só o Maestro criador; `pr` → `.notMaestro` "pr land is user-only" |
| `floor.delete` | `name`, `force` | sim | só o Maestro criador |

- Andar com terminal rodando (`floorId` igual e `isRunning`) → `floor.delete` recusa (`invalidArgs` "floor has running terminals"), mesmo com `force`.
- `admin.spawn` ganha `floor` (nome): `floorId` e `cwd` padrão = `floor.path`.
- Env de terminal em andar: `ORQ_FLOOR_NAME`, `ORQ_FLOOR_PATH`, `ORQ_BRANCH_NAME`.
- Toda mudança persiste e emite `.floor(f)` / `.floorRemoved(id)`.

- [ ] **Step 1: Write failing tests** (daemon real + repo temporário):
  - `maestroCreatesFloorAndRecruitsIntoIt`: `floor.create feat` → `recruit dev --preset shell --floor feat` → `pwd` no `dev` mostra o caminho do andar; `env` mostra `ORQ_FLOOR_NAME=feat`; evento `.floor` emitido.
  - `onlyCreatorMaestroLands`: M2 tenta `floor.land` no andar de M1 → `.notMaestro`; o admin consegue.
  - `maestroCannotLandAsPR`.
  - `floorTerminalSetsOwnStatus`: `dev` (no andar) faz `floor.status feat review` → ok; um terminal fora do andar → `.notMaestro`.
  - `deleteRefusedWithRunningTerminals`.
  - `floorsSurviveDaemonRestart`: andar criado, daemon reiniciado → `floor.list` igual e `snapshot.floors` presente.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(daemon): floor commands with creator-scoped Maestro access`.

---

### Task 5: Uso dos agentes (provedores declarativos)

**Files:** Create `Sources/OrqCore/Usage.swift`, `Sources/OrqDaemonKit/UsageService.swift`, `Resources/usage-providers/claude.json`, `Resources/usage-providers/codex.json`; Modify `Commands.swift` (`ui.usage`, admin-only), `CommandRouter.swift`, `Package.swift` (resources do OrqDaemonKit), `scripts/bundle-app.sh` se preciso; Test `Tests/OrqCoreTests/UsageModelTests.swift`, `Tests/OrqDaemonKitTests/UsageServiceTests.swift`

**Interfaces:**
```swift
public struct UsageProvider: Codable, Sendable {
  public var id: String; public var label: String; public var enabled: Bool
  public var command: [String]            // argv; nada de shell implícito
  public var timeoutSeconds: Double?      // padrão 30, máx 120
  public var parse: Parse                 // .json (stdout inteiro) | .jsonlLast(contains: String) (última linha que contém)
  public var windows: [Window]            // label ("5h","7d"), usedPercent: JSON pointer, resetsAt: JSON pointer? (epoch s ou ISO-8601)
}
public struct UsageReport: Codable, Sendable, Equatable {
  public var providerId: String; public var label: String
  public var windows: [WindowValue]       // label, usedPercent: Double?, resetsAt: Date?
  public var error: String?; public var fetchedAt: Date
}
public enum JSONPointer { public static func eval(_ p: String, in v: JSONValue) -> JSONValue? }   // RFC 6901 (~0, ~1, índices)
actor UsageService {
  init(dir: URL)                          // <root>/usage/providers; semeado dos Resources se vazio
  func reports(maxAge: Duration = .seconds(300)) async -> [UsageReport]   // provedores em paralelo; cache por provedor
}
```
- `ui.usage` (admin-only) → `[UsageReport]`. Provedor inválido, desligado, com timeout, saída > 1 MiB ou JSON ilegível → `UsageReport.error` com o motivo; nunca derruba os outros.
- **Provedores padrão.** Antes de escrevê-los, investigue nesta máquina, sem gastar tokens e **sem ler credenciais** (Keychain, arquivos de token OAuth):
  - **Codex:** os eventos de rate limit nos logs de sessão (`~/.codex/sessions/**/rollout-*.jsonl`, campo `rate_limits` com `primary`/`secondary`).
  - **Claude Code:** uma forma oficial e local de consultar o uso (modo `--input-format stream-json` / pedido de controle, `claude` subcomandos). Não envie prompt.
  - Ficou sem fonte estável e local? O provedor vai com `"enabled": false` e uma nota no relatório. Registre o que encontrou.

- [ ] **Step 1: Write failing tests:**
  - `jsonPointerRFC6901`: `/a/b/0`, `/a~1b`, `/m~0n`, `""` (raiz), ponteiro ausente → nil.
  - `providerParsesWindows`: um provedor fake (`/bin/sh -c 'printf …'`) produz `usedPercent` e `resetsAt` corretos para epoch e ISO.
  - `jsonlLastPicksLastMatchingLine`.
  - `hungProviderTimesOutAlone`: provedor `sleep 60` com timeout 1 s + outro bom → o ruim dá erro "timeout" em < 3 s, o bom dá valores.
  - `hugeOutputIsCapped`: provedor que imprime 5 MiB → erro "output exceeds 1 MiB"; RAM não cresce (sem acumular além do teto).
  - `cacheHonorsMaxAge`: duas chamadas em sequência executam o comando uma vez (contador num arquivo temporário).
- [ ] **Step 2–4:** RED → GREEN; depois a investigação e os JSONs padrão.
- [ ] **Step 5:** Commit `feat(daemon): agent usage providers and ui.usage`.

---

### Task 6: App — andares, notificações do Maestro e popover de uso

**Files:** Create `Sources/OrqApp/FloorBar.swift`, `Sources/OrqApp/UsagePopover.swift`; Modify `Sources/OrqClient/DaemonClient.swift`, `Sources/OrqApp/OrqApp.swift`, `CanvasViewport.swift`, `TerminalNodeView.swift`, `NewTerminalSheet.swift`, `CordLayer.swift`; Test `Tests/OrqClientTests/FloorClientTests.swift`

**Interfaces:**
- Consumes: eventos e snapshot (Task 1), `floor.*` (Task 4), `ui.usage` (Task 5), `Notifier.shared` (1B).
- `DaemonClient`: `floors: [Floor]` (snapshot + `.floor`/`.floorRemoved`), `onNotify: ((UUID, String) -> Void)?`, `createFloor(name:repo:)`, `setFloorStatus(_:_:)`, `land(_:mode:message:) -> LandResult`, `deleteFloor(_:force:)`, `usage() -> [UsageReport]`, `spawn(…, floor: String?)`.
- **FloorBar** (toolbar): picker "Térreo" + andares (bolinha de status: working azul, blocked laranja, review roxo, done verde). Menu do andar: Status ▸, Land ▸ (Merge / Squash / Rebase / Abrir PR), Excluir… (confirmação; oferece "forçar" quando o erro for de alterações não commitadas). "Novo andar…" pede o nome; repo = pasta escolhida (NSOpenPanel, lembrada em UserDefaults). Erros e conflitos de land aparecem num alerta com a lista de arquivos.
- O canvas mostra só os terminais com `floorId == andarAtual` (térreo = nil). Cordas aparecem quando as duas pontas estão visíveis. O andar atual fica em UserDefaults. O viewport é compartilhado entre andares (**[call]**, YAGNI).
- `NewTerminalSheet` cria no andar atual.
- O nó do Maestro mostra uma coroa (`crown.fill`) no título.
- `.notify` → `Notifier.shared` com título "<nome do Maestro>"; clicar foca o nó (mesmo caminho da atenção).
- **UsagePopover**: botão na toolbar (`gauge`) abre um popover com uma linha por provedor: rótulo, uma barra por janela (`usedPercent`, "reinicia em 2h 10m") ou o erro. Atualiza ao abrir (`maxAge` 300 s no daemon) e a cada 5 min enquanto estiver aberto. Some do 1D, quando virar painel de doca.

- [ ] **Step 1: Write failing tests:** `FloorClientTests.appliesFloorEvents` (snapshot + `.floor` upsert + `.floorRemoved`), `notifyEventCallsHandler`, `terminalsFilteredByFloor` (função pura `visibleTerminals(_:floor:)` em OrqClient).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5 (manual, checklist para o usuário):** criar andar → recrutar nele pelo Maestro → nó aparece no andar; trocar de andar esconde e mostra os nós; land Merge pela UI; conflito mostra arquivos; `orq notify` no Maestro gera notificação; popover de uso mostra Codex/Claude ou o motivo.
- [ ] **Step 6:** Commit `feat(app): floor bar, Maestro notifications and usage popover`.

---

## Fora do 1C (registrado)
- `open-panel` do Maestro → **1D** (painéis e docas só existem lá).
- Papéis (roles), rotinas, hooks de andar (setup/run/teardown), andar a partir de PR, clone APFS de arquivos não rastreados → depois.
- Conflito de design/memória no land (§8.7) → fases 2 e 1E.
- Viewport separado por andar → depois, se fizer falta.

## Self-review (feito)
- **Spec §5:** Maestro com comandos privilegiados e alcance por corda (T2); recrutar cria corda (T2); andares com worktree, status e land merge/squash/rebase/PR (T3–T4, T6); uso por agente com janelas 5h/7d via provedores declarativos (T5–T6); persistência versionada com migração (T1). Abrir painéis foi movido para o 1D por depender do sistema de plug-ins.
- **Segurança:** o Maestro nunca recebe o admin token; `pr` (sai da máquina) é só do usuário; andares do Maestro são escopados por `createdBy`, para Maestros paralelos não pousarem o trabalho um do outro.
- **Tipos:** `Floor`, `FloorStatus`, `LandMode`, `LandResult`, `UsageReport` com os mesmos nomes em T1–T6.
- **Proporção:** 6 tasks; UI validada por checklist manual.
