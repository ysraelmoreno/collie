# Plano 1E — Memória — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Memória de longo prazo própria (decisões, mapa, armadilhas) gravada pelos agentes no repositório, injetada no Claude Code ao abrir a sessão e ao mudar de assunto, revisável num painel de doca e limpa de forma reversível.

**Architecture:** Cada memória é um arquivo markdown com frontmatter em `<repo>/.orq/memory/` (versionado, viaja com o andar). O daemon tem um `MemoryService` (actor) que mantém, por repositório, um índice **derivado** SQLite FTS5 em `<repo>/.orq/cache/memory.sqlite` (fora do git, reconstruível; estatísticas de leitura numa tabela à parte que sobrevive à reconstrução). Agentes gravam e buscam por `orq memory …`/MCP; o Claude Code recebe contexto pelos hooks `SessionStart` e `UserPromptSubmit` no mesmo `--settings` que já leva o hook `Stop`. O painel é um plug-in de doca (`memory`) do sistema do 1D.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SQLite do sistema (`import SQLite3`, FTS5), SwiftUI (painel). Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (§8 inteiro, §7.5, §6). Mockup do painel: `.superpowers/brainstorm/62775-1792370484/content/memory-panel.html`. Roteiro: `docs/superpowers/plans/2026-10-18-phase1-roadmap.md`. Base: `main` em `9635289` (1A–1D + correção de asks). Referência de ideias (não código): akitaonrails/ai-memory.

## Global Constraints

- macOS **15.0**, Swift 6.2, concorrência estrita. Nenhuma dependência nova (SQLite3 do sistema).
- Memória "escrita do zero em Swift" (spec §3) — ai-memory é só referência de ideias; clean-room.
- **Agente grava sozinho; entra nas injeções na hora, antes de qualquer revisão**, marcada com origem (terminal, preset, quando, `reviewed: false`). Substituição vale na hora; descartar remove das injeções; editar atualiza (spec §8.2).
- **Nada é apagado de verdade sem o usuário; tudo reversível** (§8.5). Só a ação explícita "Esvaziar descartadas" do painel apaga arquivos.
- Armazenamento: `<repo>/.orq/memory/` versionado; índice e caches em `<repo>/.orq/cache/` (acrescentado a `<git-common-dir>/info/exclude`, sem tocar no `.gitignore` do usuário); escopo global em `<daemon root>/memory/` (§8.6).
- Injeção com tamanho limitado: início de sessão ≤ **4096 bytes**, por prompt ≤ **2048 bytes** e no máximo **5** memórias; memória já injetada na mesma sessão não se repete.
- Nada de I/O de disco/SQLite no pool cooperativo nem na main thread: fila serial dedicada por repositório. Memória do processo limitada (sem carregar corpos inteiros além do necessário).
- Acesso: memória não é terminal, não segue regra de corda — **qualquer terminal lê/grava a memória do repositório do seu `cwd`** (e a global); comandos de revisão/limpeza/apagar são **admin** (app/usuário) **[call]**.
- Protocolo `v: 1` (só comandos novos). Testes com `/bin/sh` e repositórios git temporários; suítes pesadas `.serialized`; limites de tempo folgados.

## Review Focus

1. **Arquivo de memória editado à mão / corrompido / conflito de merge** (`<<<<<<<` no arquivo depois de um land) → o índice pula o arquivo, registra o erro na lista de problemas do painel, o resto continua funcionando. Teste: Task 2 `corruptFileIsSkippedAndReported`.
2. **Dois "vigentes" do mesmo assunto depois de um land** (cada andar gravou um) → o mais recente fica vigente, o outro vira substituído (§8.7). Teste: Task 2 `twoActiveSameSubjectKeepsNewest`.
3. **Prompt enorme ou cheio de símbolos** (cole de log, 1 MB) no hook de prompt → busca com consulta FTS sanitizada e cortada, responde em < 1 s, nunca erro de sintaxe FTS. Teste: Task 2 `ftsQueryIsSanitized` + Task 5 `hugePromptIsBounded`.
4. **Daemon fora do ar quando o hook do Claude roda** → o hook sai em silêncio (código 0, sem saída), a sessão do Claude segue normal. Teste: Task 5 `hookWithoutDaemonIsSilent`.
5. **Terminal fora de um repositório git** (`cwd` = home) → `memory save` grava no escopo global e diz isso no resultado; nada é criado em `~/.orq`. Teste: Task 4 `saveOutsideRepoGoesGlobal`.

---

## File Structure

```
Sources/OrqCore/Memory.swift                  MemoryKind, MemoryScope, MemoryStatus, MemoryRecord, frontmatter parse/serialize
Sources/OrqDaemonKit/Memory/MemoryStore.swift arquivos: listar, gravar atômico, substituição, status
Sources/OrqDaemonKit/Memory/MemoryIndex.swift SQLite FTS5 + stats + refresh por mtime + busca/score
Sources/OrqDaemonKit/Memory/MemoryCleanup.swift plano de limpeza (decaimento, duplicatas, caminhos sumidos) e aplicação/restauração
Sources/OrqDaemonKit/Memory/MemoryService.swift actor: repositórios, fila serial por repo, sessões injetadas
Sources/OrqDaemonKit/MemoryCommands.swift     memory.* no router
Sources/OrqProtocol/Commands.swift            (+ memory.*)
Sources/OrqProtocol/HookPayload.swift         (+ claude SessionStart / UserPromptSubmit)
Sources/OrqDaemonKit/AgentLaunch.swift        (+ hooks SessionStart e UserPromptSubmit no settings do Claude)
Sources/orq/HookCommands.swift                (+ claude-session-start, claude-prompt)
Sources/OrqPlugins/MemoryPanel.swift          painel (SwiftUI) Revisar / Decisões / Mapa / Limpeza
Sources/OrqPlugins/PluginPanelView.swift      (+ PanelHostContext.call)
Tests/OrqCoreTests/MemoryRecordTests.swift, Tests/OrqDaemonKitTests/{MemoryStoreTests,MemoryIndexTests,MemoryCleanupTests,MemoryCommandTests,MemoryHookTests}.swift, Tests/OrqPluginsTests/MemoryPanelTests.swift
```

---

### Task 1: Formato do registro e store de arquivos

**Files:** Create `Sources/OrqCore/Memory.swift`, `Sources/OrqDaemonKit/Memory/MemoryStore.swift`; Test `Tests/OrqCoreTests/MemoryRecordTests.swift`, `Tests/OrqDaemonKitTests/MemoryStoreTests.swift`

**Interfaces:**
```swift
public enum MemoryKind: String, Codable, Sendable { case decision, map, pitfall }
public enum MemoryScope: String, Codable, Sendable { case project, floor, global }
public enum MemoryStatus: String, Codable, Sendable { case active, superseded, archived, discarded }
public struct MemoryRecord: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID; public var kind: MemoryKind; public var scope: MemoryScope
  public var floor: String?                 // nome do andar quando scope == .floor
  public var subject: String                // chave da cadeia de substituição (normalizada: minúsculas, espaços colapsados)
  public var title: String; public var body: String
  public var path: String?                  // só .map: relativo à raiz do repo
  public var status: MemoryStatus           // padrão .active
  public var reviewed: Bool                 // padrão false
  public var pinned: Bool                   // padrão false
  public var supersedes: UUID?; public var supersededBy: UUID?
  public var origin: String                 // "<terminal> (<preset>)" ou "app"
  public var createdAt: Date; public var updatedAt: Date
}
public enum MemoryFile {
  static func render(_ r: MemoryRecord) -> String          // "---\n<chave: valor>\n---\n\n<body>\n"
  static func parse(_ text: String) throws(ProtocolError) -> MemoryRecord
  static func fileName(_ r: MemoryRecord) -> String        // "<kind>/<slug(subject) até 48>-<id 8 hex>.md"
}
struct MemoryStore {   // síncrono; quem chama roda numa fila serial
  init(dir: URL)       // <repo>/.orq/memory  ou  <root>/memory
  func all() -> (records: [MemoryRecord], problems: [(file: String, error: String)])
  func write(_ r: MemoryRecord) throws    // atômico (tmp + rename), cria subpasta do kind
  func save(_ new: MemoryRecord) throws -> (saved: MemoryRecord, superseded: MemoryRecord?)
     // ativo com mesmo kind + subject normalizado + mesmo scope/floor → status .superseded, supersededBy = novo; novo.supersedes = antigo
  func delete(_ id: UUID) throws          // só usado por "Esvaziar descartadas"
}
```
- Frontmatter: uma linha `chave: valor` por campo; strings com `:`/`#`/aspas/quebra viram JSON string (`"…"`); datas ISO-8601; ausentes → padrão. Escrita determinística (ordem fixa de chaves) para diffs limpos no git.
- Arquivo com marcador de conflito, sem frontmatter ou campo obrigatório inválido → `parse` lança; `all()` coloca em `problems` e segue.

- [ ] **Step 1: Write failing tests:** `renderParseRoundTrip` (todos os campos, título com `:`, corpo com `---` no meio), `subjectIsNormalized`, `fileNameIsStableAndSafe` (assunto `../x / Ç` → slug só `[a-z0-9-]`), `saveSupersedesSameSubject` (2º save do mesmo assunto: antigo `.superseded` com `supersededBy`, novo com `supersedes`, os dois no disco), `differentKindOrScopeDoesNotSupersede`, `corruptFileGoesToProblems`, `writeIsAtomic` (nenhum `.tmp` sobra; arquivo sempre parseável).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(memory): markdown memory records and file store`.

---

### Task 2: Índice SQLite (FTS5), estatísticas e busca

**Files:** Create `Sources/OrqDaemonKit/Memory/MemoryIndex.swift`; Test `Tests/OrqDaemonKitTests/MemoryIndexTests.swift`

**Interfaces:**
```swift
final class MemoryIndex {   // não Sendable: uso exclusivo da fila serial do repo
  init(dbFile: URL, store: MemoryStore, repoRoot: URL?) throws   // cria tabelas; WAL
  func refresh(force: Bool = false) throws -> [(file: String, error: String)]
     // reindexa arquivos com mtime/tamanho mudados (ou todos com force); remove os que sumiram;
     // resolve 2+ ativos no mesmo kind+subject+scope/floor: mais recente (updatedAt) fica, os outros viram superseded (grava o arquivo)
     // marca map com path inexistente (missingSince no stats; limpa ao reaparecer)
  func search(_ query: String, limit: Int, kinds: Set<MemoryKind>? = nil, includeInactive: Bool = false) -> [MemoryHit]
  func noteRead(_ ids: [UUID])                       // reads += 1, lastReadAt = now
  func stats(_ id: UUID) -> MemoryStats?
}
struct MemoryHit: Sendable { var record: MemoryRecord; var score: Double }
struct MemoryStats: Sendable { var reads: Int; var lastReadAt: Date?; var missingSince: Date? }
```
- Tabelas: `docs(id PRIMARY KEY, file, mtime, size, kind, status, …)`, `fts USING fts5(title, subject, body, path, tokenize='unicode61 remove_diacritics 2')`, `stats(id PRIMARY KEY, reads, lastReadAt, missingSince)` — `stats` **não** é apagada no `refresh(force:)`.
- Busca: consulta sanitizada — extrai até **32** termos `[\p{L}\p{N}_./-]{2,}` do texto (ignora o resto), cada termo entre aspas, unidos por `OR`; termos que parecem caminho (`/` ou `.ext`) também casam por prefixo com `path`. Score = `-bm25` × (1 + 0,1 × min(reads, 10)) × recência (meia-vida **30 dias** sobre `updatedAt`) × 1,5 se `pinned`; inativos (`superseded/archived/discarded`) só com `includeInactive`.
- Banco num caminho que não abre (permissão) → `init` lança; o serviço (Task 4) responde erro claro e segue sem índice para aquele repo.

- [ ] **Step 1: Write failing tests:** `searchFindsByTitleBodyAndPath`, `ftsQueryIsSanitized` (consulta com `"` `*` `(` `NEAR` e 1 MB de texto → sem erro, < 1 s, termos limitados a 32), `inactiveExcludedByDefault`, `refreshPicksUpEditsAndDeletes` (editar arquivo fora do índice → aparece na busca; apagar → some), `statsSurviveForcedRebuild`, `twoActiveSameSubjectKeepsNewest`, `corruptFileIsSkippedAndReported`, `missingMapPathIsMarked` (criar map para `src/x.swift` inexistente → `missingSince != nil`; criar o arquivo → volta a nil), `readsAndRecencyAffectScore`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(memory): derived SQLite FTS index with read stats`.

---

### Task 3: Limpeza reversível

**Files:** Create `Sources/OrqDaemonKit/Memory/MemoryCleanup.swift`; Test `Tests/OrqDaemonKitTests/MemoryCleanupTests.swift`

**Interfaces:**
```swift
struct CleanupItem: Codable, Sendable, Equatable {
  enum Action: String, Codable, Sendable { case archiveCold, archiveMissingPath, mergeDuplicate }
  var action: Action; var id: UUID; var into: UUID?   // into: o registro mantido numa mescla
  var reason: String                                  // ex.: "não lida há 45 dias", "caminho sumiu há 9 dias"
}
enum MemoryCleanup {
  static func plan(records: [MemoryRecord], stats: [UUID: MemoryStats], now: Date) -> [CleanupItem]
  static func apply(_ items: [CleanupItem], store: MemoryStore) throws -> [MemoryRecord]   // devolve os alterados
  static func restore(_ id: UUID, store: MemoryStore) throws -> MemoryRecord   // archived/superseded/discarded → active (e re-substitui o vigente do mesmo assunto)
}
```
- Valores **[call]**: frio = `pinned == false`, `status == .active`, sem leitura há **60 dias** (ou nunca lida e criada há 60 dias) e score de decaimento (meia-vida 30 dias sobre a última leitura/criação) < **0,25**. Caminho sumido há **7 dias** → `archiveMissingPath`. Duplicata = mesmo `kind` e (corpos normalizados iguais **ou** Jaccard ≥ **0,9** nos conjuntos de palavras de título+corpo) → mantém o mais recente, os outros `mergeDuplicate` (viram `superseded` com `supersededBy = into`).
- `apply` só muda `status`/`supersededBy` e grava o arquivo; **nunca apaga**. Fixadas nunca entram no plano.

- [ ] **Step 1: Write failing tests:** `coldUnpinnedIsArchived`, `pinnedNeverDecays`, `recentReadKeepsWarm`, `missingPathAfter7Days`, `duplicatesMergeIntoNewest`, `applyNeverDeletesFiles` (contagem de arquivos igual antes/depois), `restoreBringsBackAndResupersedes`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(memory): reversible cleanup plan and apply`.

---

### Task 4: Serviço e comandos `memory.*`

**Files:** Create `Sources/OrqDaemonKit/Memory/MemoryService.swift`, `Sources/OrqDaemonKit/MemoryCommands.swift`; Modify `Commands.swift`, `CommandRouter.swift`, `Daemon.swift`; Test `Tests/OrqDaemonKitTests/MemoryCommandTests.swift`

**Interfaces:**
```swift
actor MemoryService {
  init(globalDir: URL)
  func repo(for cwd: String) async -> RepoMemory     // git toplevel do cwd (worktree do andar incluído); fora de git → global
  func context(for terminal: UUID, cwd: String, limit: Int = 4096) async -> String          // resumo de sessão
  func relevant(for terminal: UUID, cwd: String, prompt: String, limit: Int = 2048, max: Int = 5) async -> String
  func endSession(_ terminal: UUID)                  // esquece o que já foi injetado (spawn/restart/exit)
}
```
- `RepoMemory` agrupa store + índice + fila serial; criado sob demanda, cacheado por raiz; `.orq/cache/` entra no `info/exclude` uma vez.

| Comando | Params | Quem |
|---|---|---|
| `memory.save` | `kind` (decision\|map\|pitfall, obr.), `subject` (obr.), `title` (obr.), `body` (rest), `path`, `scope` (project\|floor\|global; padrão project; floor exige terminal em andar) | terminal (origem = nome+preset) ou admin |
| `memory.search` | `query` (rest, obr.), `limit` (padrão 10, máx 50), `all` (flag: inclui inativas) | todos |
| `memory.list` | `kind`, `status` (padrão active), `unreviewed` (flag) | todos |
| `memory.get` | `id` | todos |
| `memory.context` | — (o mesmo texto da injeção de sessão, sem marcar sessão) | todos |
| `memory.review` | `id`, `action` (approve\|discard), `title`/`body`/`subject` opcionais (editar) | admin |
| `memory.restore` / `memory.pin` / `memory.unpin` | `id` | admin |
| `memory.cleanup` | `apply` (flag; sem ela devolve só o plano) | admin |
| `memory.purge` | — (apaga arquivos `discarded`) | admin |
| `memory.repos` | — (raízes com memória conhecidas: dos terminais e andares) | admin |
- Admin escolhe o repositório com `repo` (caminho); terminal usa o próprio `cwd`. Resultados com datas ISO-8601. Resultado diz `scope` efetivo e `file`.
- Texto da sessão (≤ 4096 B): cabeçalho `Memória do projeto (Orq) — use \`orq memory save\` para registrar decisões e \`orq memory search\` antes de reler código.` + decisões vigentes (título + 1ª linha), depois mapa (`path — título`, sem os sumidos), depois armadilhas; não revisadas marcadas `(não revisada, <origem>)`. Corta por item inteiro.
- Texto por prompt (≤ 2048 B, ≤ 5): só memórias com score acima de um mínimo e não injetadas nesta sessão; vazio se nada relevante. Lidas → `noteRead`.
- Eventos: `.pluginEvent` não; o painel recarrega por `memory.list` ao abrir/agir **[call]** (sem push no 1E).

- [ ] **Step 1: Write failing tests** (daemon real, repo git temporário): `terminalSavesAndSearches`, `saveOutsideRepoGoesGlobal` (cwd = pasta temp sem git → `scope == global`, arquivo em `<root>/memory`, nada em `~`), `floorScopeNeedsFloorTerminal`, `supersedeIsImmediateInContext`, `discardRemovesFromContext`, `reviewIsAdminOnly`, `contextIsBounded` (300 decisões → ≤ 4096 B, itens inteiros), `relevantSkipsAlreadyInjected`, `cacheDirIsExcludedFromGit` (`git status --porcelain` não mostra `.orq/cache`), `purgeDeletesOnlyDiscarded`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(memory): memory service and commands`.

---

### Task 5: Injeção no Claude Code (hooks de sessão e de prompt)

**Files:** Modify `Sources/OrqDaemonKit/AgentLaunch.swift`, `Sources/orq/HookCommands.swift`, `Sources/OrqProtocol/HookPayload.swift`, `CommandRouter.swift` (`memory.hookContext`, `memory.hookRelevant` — terminal-only, sem MCP); Test `Tests/OrqDaemonKitTests/MemoryHookTests.swift`, `Tests/OrqProtocolTests/HookPayloadTests.swift`

**Interfaces:**
- Settings do Claude (`<hooks>/<id>.claude.json`) ganha, além de `Stop`: `SessionStart` → `orq hook claude-session-start` e `UserPromptSubmit` → `orq hook claude-prompt` (timeout **5 s** cada).
- `orq hook claude-session-start`: chama `memory.hookContext` com as credenciais do terminal; imprime no stdout `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<texto>"}}` (nada se vazio). `orq hook claude-prompt`: lê o JSON do stdin (`prompt`), corta o prompt em **64 KiB**, chama `memory.hookRelevant`, imprime o mesmo formato com `"hookEventName":"UserPromptSubmit"`.
- **Qualquer falha** (daemon fora, timeout, erro) → saída vazia, código 0, linha em `hooks.log`. Nunca bloqueia o Claude.
- `memory.hookContext` marca as memórias como injetadas na sessão do terminal; `endSession` no spawn/restart/exit do terminal.
- Codex e outros: sem hook de sessão/prompt nesta fase **[call]**; usam `orq memory context`/`search` (MCP `memory_context`, `memory_search`). Registrado como limitação.

- [ ] **Step 1: Write failing tests:** `claudeSettingsHaveSessionAndPromptHooks` (JSON do settings tem `Stop`, `SessionStart`, `UserPromptSubmit` com o caminho do `orq`), `parsesUserPromptSubmitPayload`, `sessionHookOutputsAdditionalContext` (daemon real: salvar decisão, chamar o fluxo do hook → JSON com o título), `promptHookInjectsOnlyRelevantOnce` (2ª vez o mesmo prompt → vazio), `hugePromptIsBounded` (1 MB → < 1 s, saída ≤ 2048 B), `hookWithoutDaemonIsSilent` (socket inexistente → stdout vazio, exit 0), `restartEndsSession` (depois de `admin.restart` a mesma memória volta a ser injetada).
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5:** Commit `feat(memory): inject memory into Claude Code via session and prompt hooks`.

---

### Task 6: Painel de Memória (plug-in de doca)

**Files:** Create `Sources/OrqPlugins/MemoryPanel.swift`; Modify `Sources/OrqPlugins/PluginPanelView.swift` (`PanelHostContext.call`), `Sources/OrqProtocol/Plugins.swift` (registrar `memory`: título "Memória", posições doca esquerda/direita/baixo, padrão doca direita, sem comandos), `Sources/OrqApp/OrqApp.swift` (registrar a view; `call` via `DaemonClient` com admin token); Test `Tests/OrqPluginsTests/MemoryPanelTests.swift`

**Interfaces:**
- `PanelHostContext.call: @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue` (admin, pelo DaemonClient do app).
- `@MainActor final class MemoryPanelModel: ObservableObject` (testável sem UI): `repos`, `repo`, `tab` (`.review | .decisions | .map | .cleanup`), `load()`, `approve(_:)`, `discard(_:)`, `edit(_:title:body:subject:)`, `restore(_:)`, `pin(_:)`, `planCleanup()`, `applyCleanup()`, `purge()`; `problems` (arquivos com erro).
- Abas (cópia em português, seguindo o mockup): **Revisar** (não revisadas desde a última revisão: Aprovar / Editar / Descartar, com origem e data), **Decisões** (vigentes; cada uma expande o histórico da cadeia de substituição com Restaurar), **Mapa** (caminho + título; sumidos com etiqueta "caminho sumiu" e Arquivar), **Limpeza** (plano com motivo de cada item, "Aplicar limpeza", seção Descartadas com Restaurar e "Esvaziar descartadas…" com confirmação dizendo quantos arquivos serão apagados).
- Seletor de repositório no topo (`memory.repos`); faixa de problemas quando houver arquivos inválidos.

- [ ] **Step 1: Write failing tests** (modelo com `call` falso): `reviewTabListsUnreviewed`, `approveCallsReviewAndRefreshes`, `decisionHistoryShowsChain`, `mapMarksMissing`, `cleanupApplyThenRestore`, `purgeRequiresConfirmationFlag`.
- [ ] **Step 2–4:** RED → GREEN.
- [ ] **Step 5 (manual, checklist):** abrir "Memória" na doca direita; num Claude, pedir uma decisão e ver `orq memory save` aparecer em Revisar; abrir nova sessão do Claude e ver o contexto injetado (perguntar "o que decidimos sobre X?"); land de um andar com memória.
- [ ] **Step 6:** Commit `feat(plugins): memory review panel`.

---

## Fora do 1E (registrado)
- Injeção automática no Codex (sem hook de sessão/prompt equivalente) → quando houver.
- Vetores/embeddings (§8.3 opcional) e consolidação por LLM ("sonho", §8.5) → fora da v1.
- Lembrete ativo no fim do turno (o cabeçalho da sessão já instrui o agente) **[call]**.
- Decisões gravadas por plug-ins (design system) → fase 2.
- Medição "agente usa a memória em vez de reler" (§8.3) → teste de uso manual + métrica depois.

## Self-review (feito)
- **§8.1** tipos decisão/mapa/armadilha e escopos projeto/andar/global (T1, T4). **§8.2** grava sozinho, entra na hora, substituição, descartar/editar (T1, T4, T6). **§8.3** injeção de sessão e por assunto com tamanho limitado e busca textual + caminhos (T2, T4, T5). **§8.4** painel com as quatro abas (T6). **§8.5** substituídas fora das injeções e restauráveis, caminhos sumidos, decaimento, fixadas, duplicatas, nada apagado sem o usuário (T2, T3, T6). **§8.6** markdown no repo, índice derivado fora do git, global na pasta do app (T1, T2, T4). **§8.7** memória viaja com o andar (arquivos no worktree) e conflito de cadeia resolvido pelo mais recente (T2).
- **Tipos:** `MemoryRecord`, `MemoryKind/Scope/Status`, `MemoryStore`, `MemoryIndex`, `MemoryHit`, `MemoryStats`, `CleanupItem`, `MemoryService`, `MemoryPanelModel` iguais em T1–T6.
