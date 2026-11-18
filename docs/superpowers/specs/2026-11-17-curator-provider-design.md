# Provedor do curador de memória — design

Status: **aprovado pelo dono (2026-11-17, ask 199a4388)**, com as 8 chamadas como recomendadas. Revisão
independente aplicada (B1–B5, I1–I13, M1–M10). Reescopo do dono (ask e4d07547): **v1 = Claude (atual, endurecido) +
Cursor**; Codex, modelos locais, Apple e chave de API ficam para depois. Em implementação. Plano: `docs/superpowers/plans/2026-11-17-curator-provider.md`.

## Intenção e porquê

O curador é o modelo headless que organiza a memória do Collie: julga correções, ativa ou descarta propostas, lê
conversas, junta duplicatas, confere memórias contestadas, propõe procedimentos e indexa documentos. Hoje ele **só**
roda como `claude -p`. Quem não tem assinatura Claude fica sem a parte da memória que aprende sozinha. O dono quer
poder trocar o curador, e o padrão alternativo é o **Cursor** (“Codex não é tanto algo para padronizar, e sim o
Cursor”).

Fracasso mesmo funcionando: gastar token ou cobrança por uso em silêncio; mandar trechos de conversa para a nuvem do
Cursor sem o usuário saber; o Cursor (um agente com ferramentas) rodar comando, escrever arquivo, buscar na web ou
carregar MCP, hooks, rules e skills do usuário; um modelo ativar, apagar ou reescrever memórias sem pergunta; perder
fila, histórico ou ciclo de vida na troca; testes que gastam token ou abrem rede.

## Estado atual (verificado no código, main em aa4427a)

### O curador

- `CuratorRunner` (`Curator/CuratorRunner.swift:26-29`) já é o ponto de troca: `availability()` e
  `run(call, model:, timeout:)`. Única implementação `ClaudeCuratorRunner`, escolhida em `CommandRouter.swift:249-250`;
  testes injetam `FakeCurator` (`Daemon.swift:123-124`).
- `ClaudeCuratorRunner`: `claude -p` com `--tools ""`, MCP vazio estrito, `--setting-sources project,local`,
  `--safe-mode`, sem slash commands, sem sessão, `--permission-prompts none`, `--max-budget-usd 0.05`,
  `--json-schema`, `--system-prompt` e **o input em argv** (`CuratorRunner.swift:68-73`); cwd temporário vazio 0700;
  ambiente sem `COLLIE_*` e `strippedKeys` (`:50-51`, `:114-117`); `HOME` = `config.sandboxHome ?? home real`
  (`CommandRouter.swift:168`). Parse em `:78-104`. Disponibilidade só olha `loggedIn` (`:136-155`).
- **Sandbox**: perfil do *terminal* em modo strict, id fixo `…c0de`, arquivo fixo `curator/curator.sb`
  (`:34`, `:161-180`). Strict **lê o disco inteiro** menos `readClosed` (`SandboxProfile.swift:135-141`,
  `EssentialPaths.swift:105`); `homeWrites` vale para todos e inclui `~/.claude.json*` (R13), `Library/Keychains`
  (R12), `.claude/.credentials.json*`, `.codex/auth.json` (`EssentialPaths.swift:22-29`, `SandboxProfile.swift:149`);
  rede liberada (`:104`); `/bin/ps` sem sandbox (`:237`).
- `Curator` (`Curator.swift`): fila durável `curator/jobs/`, um job por vez por prioridade (`:8-11`), tick 10 min,
  3 tentativas e `failed/`, fila máxima 200 (`:48`, cheia recusa; correção expulsa propostas, `:127-131`), entrada
  cortada **pelo fim** em 12 000 escalares (`:45`, `:265-268`), timeout 60 s (`:46`), `Config { cap = 40; model =
  "haiku" }` com `Codable` sintetizado (`:51`, `:81`), `setCap` regrava tudo (`:149-151`). `.unavailable` do `run`
  vira `.internal` e gasta tentativa (`:280-282`). `curator/` fora do `.colliebackup` (`DataBackup.swift:17`).
- Evento `curatorRun` (`Curator.swift:272-283`, `MemoryEvents.swift:23-28`). `memory.curator` é admin-only
  (`MemoryCommands.swift:42-47`, `CommandRouter.swift:347-361`) e está em `memoryReads` (`MemoryCommands.swift:12-13`).

### Validação e fence

- Três formatos de saída: `{"ops":[…]}` com `CuratorOps.validate` (`CuratorOps.swift:75-80`; correção, propostas,
  pitfall, consolidação, verificação, procedimento `ProcedureDetector.swift:163-164`); `{"items":[…]}` da conversa
  (`ConversationCapture.swift:30-45`, `:62-65`); `{"chunks":[…]}` do docTerms (`DocTerms.swift:28-38`). `validate`
  nunca lança (lixo → `([], 1)`); os handlers não devolvem `dropped` ao `Curator`.
- Fence `DADOS-<nonce>` com `DADOS-` do dado reescrito (`MemoryLearning.swift:65-79` e builders). Builders usam o
  `Curator.inputMax` estático (`ConversationCapture.swift:59`, `:195`; `Consolidation.swift:166`, ao enfileirar).
  Scrub `LotBoards.scrub` (`Lots/LotBoard.swift:161-173`) só pega formatos marcados.

### Fraquezas que já existem com o Claude (obrigatórias, vêm primeiro)

- **E1. Verificação falha aberta**: `applyVerdict` (`Memory/MemoryService.swift`) só trata `retire` do id como
  `invalid`; `{}` ou lixo é “valid” (limpa contestação ou promove a longTerm). `runVerifyJob`
  (`MemoryVerify.swift:102-120`) descarta o `dropped`.
- **E2. Origem não decide nada**: a conversa grava `decision`/`pitfall` `.active` (`ConversationCapture.swift:89`)
  fora do `applyOps`; a ativação de 14 dias (`LifecyclePass.swift:76-87`) não olha quem criou.
- **E3. Método de login não conferido** (Claude: `loggedIn` só).
- **E4. Prompt em argv**, legível por outros processos do usuário (`/bin/ps` roda sem sandbox nos terminais).
- **E5. Perfil do curador é o do terminal** (lê o disco, escreve `~/.claude.json`, Keychains).
- **E6. Cota/crédito esgotado leva jobs a `failed/`** (`is_error` → `.unavailable` → `.internal`).
- **E7. `config.json` sem migração** (chave nova quebra a leitura; daemon antigo apaga o que não conhece).

### Os jobs e o que acontece sem curador

| Job | Saída | Sem curador |
|---|---|---|
| `correction` | ops | citação já salva como `proposed` (`MemoryLearning.swift:147-153`) |
| `verifyContested` | ops (`retire`) | checagem objetiva falhou → arquiva; senão “deferred”; 14 dias → “Precisa de você” |
| `verifyPromotion` | ops | nunca promove |
| `proposals` | ops | ficam `proposed` |
| `pitfall` | ops | mesma classe por assunto somada sem modelo |
| `conversation` | items | nada capturado; a marca não anda (só transcrições do Claude, `ConversationCapture.swift:265`) |
| `consolidate` | ops | limpeza determinística e ciclo de vida rodam |
| `procedure` | ops | nenhum proposto |
| `docTerms` | chunks | busca por palavras + NLEmbedding; sem digest nem undo quando roda |

Sem curador a fila espera; cheia (200), recusa; 3 falhas → `failed/`. Roda sempre sem curador: save, search,
context, checklist, hooks, docs, list/get/review/promote/supersede/restore/pin/flag, cleanup/purge/undo, ciclo de
vida, skills.

### O que o usuário vê

Painel (`MemoryPanel.swift:175-180`, `:416-424`; `CuratorInfo` exige `costUSD: Double`, `:47-49`),
observabilidade (`MemoryObservability.swift:71-75`), CLI `collie memory curator [--cap N]`, Preferências › Memória
só com dois toggles (`PreferencesView.swift:262-268`).

## Cursor (`cursor-agent`) — pesquisa

Feita com `--help`/`--version`/`status` (cursor-agent 2026.11.13-eacade1, nesta máquina), leitura do bundle instalado,
o spike `docs/superpowers/spikes/2026-10-22-cursor/REPORT.md` e a documentação pública. Nenhum prompt foi enviado.

**(a) Comando headless.** `cursor-agent -p/--print [prompt...]`; `--output-format text|json|stream-json`
(<https://cursor.com/docs/cli/reference/output-format>). `json`: um objeto `{type:"result", subtype:"success",
is_error:false, duration_ms, duration_api_ms, result, session_id, request_id?}`; a resposta final é `result` (texto).
**Sem `usage`** em nenhum formato. Erro: sai ≠ 0, mensagem no stderr, nenhum JSON. Sem prompt: “Error: No prompt
provided for print mode” (bundle). Sem login, não interativo: “Error: Authentication required. Run 'cursor-agent
login', pass --api-key/--auth-token, or set CURSOR_API_KEY/CURSOR_AUTH_TOKEN.” (spike §, `REPORT.md:121`). Login sem
gastar token: `cursor-agent status --format json` → `{status: "authenticated", isAuthenticated, hasAccessToken,
hasRefreshToken, userInfo{email, userId, firstName, lastName, teamId, teamName, createdAt}}` (rodado aqui; exit 0).
Códigos de saída além de 0/≠0 não documentados. Primeira conexão pode levar 10–15 s e houve relatos de `-p` travado
(<https://forum.cursor.com/t/cursor-agent-p-print-headless-mode-hangs-indefinitely-and-never-returns/150246>).

**(b) Ferramentas.** `-p` “has access to all tools, including write and shell”; em print mode “file edits inside the
workspace” e comandos “on your allowlist or that can run in the sandbox” rodam **sem aprovação**; o que não está
permitido é **rejeitado** (<https://cursor.com/docs/cli/headless>). `--force/--yolo` aprova tudo (nunca usar).
`--mode ask` = Q&A somente leitura (<https://cursor.com/docs/cli/using>). Permissões `Shell()`, `Read()`, `Write()`,
`WebFetch()`, `Mcp(server:tool)`, deny vence allow (<https://cursor.com/docs/cli/reference/permissions>);
`approvalMode` = `allowlist | auto-review | unrestricted` (<https://cursor.com/docs/cli/reference/configuration>).
**Nesta máquina o `~/.cursor/cli-config.json` do usuário tem `approvalMode: "unrestricted"`**: herdar a config do
usuário anularia a allowlist. O “Not in allowlist” visto nos terminais (memória cf2ba1e0) é a defesa útil **só** com
`approvalMode: "allowlist"`, sem `--force`, e com `--sandbox disabled` (com sandbox ligado, todo comando que cabe no
sandbox roda sem aprovação). MCP: lê `~/.cursor/mcp.json` e o do projeto; sem `--approve-mcps` pede aprovação.
Rules: `.cursor/rules`, `AGENTS.md`, `CLAUDE.md` na raiz do workspace (cwd vazio = nenhum). Hooks: de
`/Library/Application Support/Cursor/hooks.json`, `~/.cursor/managed/…`, `homedir()/.cursor/hooks.json` e **dos
hooks do `~/.claude/settings.json` do usuário** (`REPORT.md:31-45`, `:87`) — rodam dentro do cursor-agent.
Skills/plugins de `~/.cursor`.

**(c) Workspace Trust.** `--trust`: “Trust the workspace without prompting (headless mode only)”
(<https://cursor.com/docs/cli/reference/parameters>). Sem ele, em pasta nova, o modo interativo mostra o diálogo
(memória 8c09343a); em `-p` há relatos de espera. Com cwd temporário vazio, `--trust` confia numa pasta descartável.

**(d) Saída estruturada.** **Não há `--json-schema`/`--output-schema`.** O schema vai no texto do prompt; a resposta
`result` é parseada (`unfenced` + JSON), e o resto é o portão: `validate`/`decode`/`parse`, veredito fail-closed e
pausa por saída ruim. Modelo: `--model <id>`; `cursor-agent models` lista os da conta (rede, sem gerar). “auto” não
aparece na referência; sem `--model` vale o padrão da conta.

**(e) Ambiente e cobrança.** Mudam conta/destino: `CURSOR_API_KEY`, `CURSOR_AUTH_TOKEN`, `CURSOR_API_ENDPOINT`,
`--api-key`, `--auth-token`, `-H`, `-e/--endpoint`, `AGENT_CLI_CREDENTIAL_STORE`, `CURSOR_CONFIG_DIR`,
`XDG_CONFIG_HOME` (bundle e `--help`). O bundle distingue `authSource` `login | api-key | auth-token`, mas o `status`
não expõe isso: o Collie garante “só login” removendo as variáveis e nunca passando as flags. A doc não diz se chave é
cobrada diferente (<https://cursor.com/docs/cli/reference/authentication>). **O próprio plano do Cursor pode ter
cobrança por uso** além do incluído (configuração da conta/time): o Collie não vê isso, então o consentimento diz.

**(f) Estado e login.** Credenciais no Keychain por padrão (`AGENT_CLI_CREDENTIAL_STORE=file|memory` muda;
`REPORT.md:58`). Medido aqui com `status`: `CURSOR_CONFIG_DIR=<vazio>` **mantém o login** e cria um
`cli-config.json` novo com `approvalMode: "allowlist"`, `permissions.allow: ["Shell(ls)"]`; **`HOME=<vazio>` perde o
login** (`unauthenticated`). `CURSOR_CONFIG_DIR` move só o `cli-config.json`, não `hooks.json` (`REPORT.md:56`, `:83`).
Binário: `~/.local/bin/cursor-agent` → `~/.local/share/cursor-agent/versions/<v>/cursor-agent`, um script bash
(`/usr/bin/env bash`, `realpath`, `dirname`, `basename`) que roda `cursor-agent-sea` (Node empacotado) e workers.

**(g) Tempo, custo.** Sem `usage` nem custo: `costUSD` nil, tokens nil; o painel mostra só jobs. Timeout inicial
120 s (10–15 s só de conexão; a medir no R3). Disponibilidade com cache 600 s/30 s como o Claude.

**(h) Privacidade.** Os trechos fenced (conversas, documentos, memórias) vão para a nuvem do Cursor e dos
fornecedores de modelo dele, sob o Privacy Mode da conta (configuração do Cursor, não do Collie).

## Metas

1. Corrigir E1–E7 no curador atual.
2. Escolher o provedor do curador (Claude ou Cursor) e o modelo, por Mac, nas Preferências e na CLI admin.
3. Mesma fila, prompts, fence e validação; um provedor não ativa, apaga nem reescreve sozinho (se limitado).
4. Cursor sem ferramentas, MCP, hooks, rules ou skills do usuário, e só no login do usuário.
5. Consentimento explícito ao escolher o Cursor, com o destino dos dados.
6. Troca sem perder fila, digest, ciclo de vida nem estatísticas.
7. Interface pronta para o próximo provedor sem retrabalho.
8. Testes com fakes e fixtures, sem rede nem token.

## Não metas

- Codex, modelos locais, Apple, chave de API na v1 (ver “Fica para depois”).
- Provedor por repositório/cercado/espaço ASM.
- Capturar conversas do Cursor (a captura lê só transcrições do Claude).
- Mudar prompts, schemas de job ou prioridades.
- Backup de `curator/` (restaurar volta ao Claude, o lado seguro).

## Abordagens

### A. Correções E1–E7, interface por provedor, Cursor isolado com HOME e login próprios (recomendada)

O curador Cursor roda com `HOME=<root>/curator/cursor-home`, `CURSOR_CONFIG_DIR` dentro dela com um
`cli-config.json` fechado, credencial em arquivo (`AGENT_CLI_CREDENTIAL_STORE=file`) e um login próprio feito uma
vez pelo usuário. Nada de `~/.cursor`, `~/.claude/settings.json`, MCP, skills ou plugins do usuário. Custo: mais um
login. Ganho: isolamento real, e o perfil Seatbelt não precisa do Keychain.

### B. HOME real + `CURSOR_CONFIG_DIR` próprio

Login de graça (Keychain), mas carrega hooks do `~/.claude/settings.json`, `~/.cursor/hooks.json`, hooks do time,
`mcp.json`, skills e plugins do usuário. Só o Seatbelt (exec allowlist) impediria os hooks de fazer algo. Fica como
alternativa se o R2 mostrar que o login em arquivo não funciona.

### C. Esperar flag de schema/sem ferramentas do Cursor

Não existe hoje; deixa o dono sem alternativa ao Claude.

## Design

### 0. Ordem

**Correções do estado atual primeiro** (independem de provedor): E1, E7, E2, E5, E4+E6, E3. Depois a interface por
provedor (provedor, resultado do job, pausa, `inputMax` nos builders, confiança limitada) e o `CursorCuratorRunner`.
E1 é o mais urgente: um `{}` limpa uma contestação hoje.

### 1. Interface

```swift
enum CuratorProvider: String, Codable, CaseIterable, Sendable { case claude, cursor }   // depois: codex, ollama, apple, apiKey
enum CuratorTrust: String, Codable, Sendable { case full, limited }                    // em CollieCore (vai no registro)

struct CuratorProviderInfo: Sendable {
    var provider: CuratorProvider
    var trust: CuratorTrust       // claude: full; cursor: ver Minhas chamadas (recomendado limited na v1)
    var destination: String       // "Anthropic", "Cursor"
    var structuredOutput: Bool    // claude: true (--json-schema); cursor: false (schema no prompt)
    var reportsUsage: Bool        // claude: true; cursor: false
    var timeout: Duration         // claude 60 s; cursor 120 s (medir no R3)
    var inputMax: Int             // escalares; 12 000 nos dois
}

protocol CuratorRunner: Sendable {
    var info: CuratorProviderInfo { get }
    func availability() async -> CuratorAvailability        // sem token; cache 600 s / 30 s; .exhausted(motivo, until:)
    func models() async -> [String]                         // [] = texto livre
    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput
}
```

- `CuratorOutput`: `inputTokens/outputTokens: Int?`, `costUSD: Double?`, `curatedBy: CuratedBy`. `CuratorStatus.costUSD`
  continua `Double` (app antigo). Evento `curatorRun`: `provider`, `model`; tokens/custo ausentes no Cursor.
- `Curator` guarda `[CuratorProvider: any CuratorRunner]`; `DaemonConfig.curatorRunners` injeta fakes.
- **Config (E7)**, decodificação manual com `decodeIfPresent`: `{ cap, model, provider = "claude", models:
  {provider: modelo}, consented: [provider] }`; `model` continua o do Claude; provedor desconhecido = claude. Daemon
  antigo que regrave o arquivo apaga `provider`/`consented`: o novo volta a Claude sem consentimento (lado seguro).
- `memory.curator`: `cap`, `provider`, `model`, `consent`, `test`, `testCall`; herda admin-only; continua em
  `memoryReads`.
- Perfil e sandbox id **por chamada** (`curator/run-<uuid>.sb`, apagado no fim).
- Próximo provedor entra com um runner novo, um `info` e um caso no enum; nada do `Curator`, dos handlers nem da UI
  muda além da lista.

### 2. Validação e confiança

**2.1 Origem (E2).** `MemoryRecord.curatedBy: {provider, model, trust}?` em todo registro que o curador cria, ativa,
junta ou reescreve (nil = usuário/agente/determinístico). A regra dos 14 dias pula `trust == .limited`.

**2.2 Veredito fail-closed (E1).** `runVerifyJob` exige saída legível e `dropped == 0`, senão o job falha (gasta
tentativa). `applyVerdict` recebe `.invalid | .valid | .undecided`: `retire` do id = invalid; `{"ops":[]}` = valid;
o resto = undecided (não limpa, não promove).

**2.3 Confiança limitada** (se o provedor for `.limited`):

| Caminho | Full | Limited |
|---|---|---|
| `create` | como hoje | `proposed` |
| conversa `decision`/`pitfall` | `active` | `proposed` |
| `activate`, `retire`, `drop`, `supersede`, `merge`, `score` < 0 | aplica | `ask` em “Precisa de você” |
| `bump`, `score` > 0, docTerms | aplica | aplica |
| `verifyContested` valid | limpa | não limpa (só a checagem objetiva arquiva) |
| `verifyPromotion` | promove | não é enfileirado |
| ativação de 14 dias | ativa | registro limitado fica de fora |

**2.4 Resultado do job e pausa.** Cada handler devolve `CuratorJobResult { ok | junk | allDropped }`; vazio
(`{"ops":[]}`, `{"items":[]}`, `{"chunks":[]}`) é ok. Últimas 20 chamadas do provedor ativo com ≥ 10 ruins →
indisponível com “saída inválida em N de 20 (troque de modelo)”; trocar de modelo/provedor ou um `testCall` ok zera.

**2.5 Entrada.** O `inputMax` do provedor ativo vai aos builders **na execução**; se não cabe, recorta **dentro** do
fence; o `Curator.call` não corta mais: entrada acima = job falha.

**2.6 Prompt sem schema nativo.** Para `structuredOutput == false`, o runner junta: instruções + “Responda só com um
objeto JSON que siga este JSON Schema, sem texto antes ou depois:” + schema + dados fenced. A resposta passa por
`unfenced` e `JSONDecoder`; qualquer outra coisa é `junk`.

### 3. `CursorCuratorRunner`

Chamada, dentro do perfil do curador:

```
sandbox-exec -f <perfil> cursor-agent -p --output-format json --mode ask --sandbox disabled --trust \
  --workspace <cwd vazio> [--model <id>]           # prompt pelo stdin se o R3 confirmar; senão argv (Minhas chamadas)
env: HOME=<root>/curator/cursor-home  CURSOR_CONFIG_DIR=<root>/curator/cursor-home/.cursor
     AGENT_CLI_CREDENTIAL_STORE=file  (+ PATH, LANG, TMPDIR; nada mais do usuário)
```

- **Config fechada** escrita pelo daemon antes de cada chamada em `CURSOR_CONFIG_DIR/cli-config.json`:
  `approvalMode: "allowlist"`, `permissions.allow: []`, `permissions.deny: ["Shell(*)", "Write(**)", "Read(**)",
  "WebFetch(*)", "Mcp(*:*)"]`, `autoAcceptWebSearch: false`, `sandbox.mode: "disabled"`. Se o Cursor recusar
  `Read(**)`, o R3 decide tirar.
- **HOME própria** vazia (0700): nenhum `~/.cursor/{hooks.json,mcp.json,skills,plugins,managed}` nem
  `~/.claude/settings.json`. Login próprio uma vez: Preferências “Entrar no Cursor para o curador” abre um terminal
  do Collie com `HOME=… CURSOR_CONFIG_DIR=… AGENT_CLI_CREDENTIAL_STORE=file cursor-agent login`.
- **Nunca** `--force`, `--yolo`, `--approve-mcps`, `--api-key`, `--auth-token`, `-H`, `-e`, `--plugin-dir`,
  `--worktree`, `--resume`, `--continue`.
- **Disponibilidade**: `cursor-agent` no PATH; `cursor-home` existe; `status --format json` (mesmo env e perfil)
  com `status == "authenticated"` e `isAuthenticated == true`; senão “cursor sem login para o curador”. Cache
  600 s / 30 s. Erro com “usage limit”, “rate limit”, “quota” ou “upgrade” no stderr → `.exhausted`.
- **Saída**: exit 0 e o objeto `type == "result"`, `is_error == false` → `result` → JSON. Exit ≠ 0 → stderr (300
  caracteres) no motivo; “Authentication required” → indisponível sem gastar tentativa.
- `info = (.cursor, <trust>, "Cursor", structuredOutput: false, reportsUsage: false, 120 s, 12 000)`.

### 4. Perfil Seatbelt dedicado do curador (E5)

`CuratorSandboxProfile` próprio, para Claude e Cursor:

- `(deny default)`; `process-exec` só dos executáveis do provedor (Claude: o binário; Cursor: o script, `/usr/bin/env`,
  `/bin/bash`, `/usr/bin/realpath`, `/usr/bin/dirname`, `/usr/bin/basename`, `cursor-agent-sea` e o worker da
  versão), o que impede hooks globais (`/Library/Application Support/Cursor/hooks.json`) de rodar programas.
- Leitura: sistema (`/System`, `/usr/lib`, `/usr/share`, `/private/var/db/dyld`, certificados, fuso), a pasta do
  executável, o cwd, o estado do provedor. Escrita: o cwd e o estado (Claude: `.claude/.credentials.json*` e os dirs de
  estado; `~/.claude.json*` só se o R2 mostrar que precisa; Cursor: `cursor-home`). Claude precisa do Keychain
  (login em Keychain): leitura/escrita de `Library/Keychains` e `mach-lookup` do `securityd` só no perfil do Claude.
- Sem `homeWrites`, sem `/bin/ps` sem sandbox, sem sockets Unix; rede IP liberada (precisam da API).
- Teste do texto renderizado: `~/.ssh`, `~/.claude.json` (no Cursor), `~/.config/gh`, `~/.cursor`, `~/.codex`,
  `~/.claude/settings.json` (no Cursor), um repositório qualquer: negados.

### 5. Claude endurecido (E3, E4, E6)

- E3: cada provedor classifica o próprio login em `CuratorBilling` (`included` / `metered` / `unknown`); a política é
  uma só, no `Curator`: só `included` cura; `metered` ou `unknown` → “<Provedor>: login com cobrança por uso ou não
  reconhecido; consentimento necessário” (a Task 12 troca por pedir consentimento). Claude, pelo R1 (só assinatura):
  `authMethod` "claude.ai" + `apiProvider` "firstParty" = assinatura, qualquer `subscriptionType`; sinal de API,
  Console ou Bedrock/Vertex = `metered`; o resto = `unknown` (fail-closed). Nenhum campo do status (e-mail, org) é
  exibido.
- E4: prompt por stdin (`claude -p` sem prompt no argv; pinar no R1).
- E6: `.exhausted` para “Credit balance”, “usage limit”, “rate limit”, “quota”: jobs esperam sem gastar tentativa;
  “cota do <provedor> esgotada até HH:MM”.

### 6. Privacidade e consentimento

- Folha **só para provedores que não são o Claude atual** (confirmado para o Cursor): “O curador lê trechos das suas
  conversas, documentos e memórias deste Mac e os envia ao Cursor e aos fornecedores de modelo dele, sob o Privacy
  Mode e o plano da sua conta. Se o seu plano cobra por uso além do incluído, os jobs do curador contam. Nada é
  enviado por chave de API.” Confirmar grava `consented`; sem isso, “falta confirmar nas Preferências”.
- Claude: consentimento implícito (é o de hoje); o destino aparece na linha do painel.
- Desvio (Task 12, 2026-11-18): login com cobrança por uso ou não reconhecido (`metered`/`unknown`) só cura com o
  consentimento do provedor gravado, **Claude incluído** (conta de API): a folha do Claude diz o destino (Anthropic) e
  que cada job conta na cobrança por token. Com assinatura, o Claude continua sem folha.

### 7. UX

```
Curador da memória
  Provedor   [ Cursor ▾ ]   ● disponível · dados vão para o Cursor
             Claude · Cursor (entrar…) · Desligado
  Modelo     [ padrão da conta ▾ ]   (lista de `cursor-agent models`; Claude: haiku/sonnet)
  Limite     [ 40 ] jobs por dia
  [ Testar agora ]  → "cursor logado · sem custo informado"   [ Testar com uma chamada… ]
  Confiança limitada: criar vira proposta; ativar, apagar ou reescrever vira pergunta.   (se limited)
```

- **Testar agora**: `availability()` + `models()`; zero geração. **Testar com uma chamada**: 3 jobs sintéticos (um
  por formato), contam no limite, mostram o `CuratorJobResult`; com confirmação.
- **Sem Claude**: “curador indisponível: claude não encontrado · Cursor instalado: [Configurar]”. Nunca troca sozinho.
- **Provedor some/logout**: motivo com o nome, jobs esperam. **Troca**: só `config.provider`; o job em andamento
  termina no antigo; fila, digest, ciclo de vida e eventos ficam.
- Linha: Claude como hoje; Cursor “12/40 hoje · Cursor (sem custo informado)”; `.exhausted`: “cota do cursor esgotada
  até HH:MM”.

### 8. Migração e compatibilidade

Config por Mac. ASM: cada Mac cura os próprios candidatos; com limitado, classificação `none`. Daemon antigo + app
novo: `provider` ausente → seção desabilitada (“reinicie o serviço para usar isto”). App antigo + daemon novo: campos
extras ignorados, `costUSD` `Double`. Registros sem `curatedBy` = como hoje.

### 9. Custos e limites

Limite em jobs/dia, um número (o quarto das correções vale para todos), padrão 40. Claude: `--max-budget-usd 0.05`.
Cursor: sem teto em dólar; o freio é limite de jobs + entrada + timeout + `.exhausted`. Fila um job por vez; provedor
lento só reduz vazão; correções na frente.

### 10. Testes

`FakeCurator` com `info` configurável. Correções: `VerifyJobTests`, `CuratorQueueTests` (config), `MemoryRecordTests`,
`ConversationApplyTests`, `LifecyclePassTests`, `CuratorSandboxProfileTests`, `CuratorRunnerTests`. Provedor:
`CuratorProviderTests`, `CuratorTrustTests`, `CursorCuratorRunnerTests` (script falso `cursor-agent` no PATH grava argv,
stdin e env; fixtures `status` e `json`). Só `--filter`; nada chama `claude`/`cursor-agent` reais.

## Decisões

- v1 = Claude endurecido + Cursor; E1–E7 primeiro, E1 antes de tudo.
- Origem `curatedBy` em todo registro curado; veredito explícito fail-closed.
- Perfil Seatbelt dedicado `deny default` por chamada, sem `homeWrites`.
- Cursor com HOME, config e login próprios; `--mode ask`, `--sandbox disabled`, `--trust`, allowlist vazia e deny de
  tudo; nunca as flags de força, MCP, chave ou endpoint.
- Schema no prompt quando o provedor não tem schema nativo; validação e pausa fazem o resto.
- Config por Mac, decodificação tolerante; consentimento só para não-Claude; nunca troca automática.

## Minhas chamadas (aprovadas pelo dono em 2026-11-17, todas como recomendadas)

1. **Confiança do Cursor**: recomendo **`limited` na v1** (sem schema nativo, modelo variável); revisar depois de
   2 semanas olhando a pausa e o digest. Alternativa: `full` e contar com o undo.
2. **Conversa do Claude gravando decision/pitfall como `active`**: recomendo manter (só registrar a origem).
   Alternativa: tudo `proposed` também no Claude.
3. **Pausa por saída ruim** com 10 de 20: recomendo manter.
4. **Limite diário**: recomendo 40 para os dois, sem padrão diferente para o Cursor.
5. **Consentimento**: folha só para não-Claude, com a frase sobre cobrança por uso. Recomendo manter.
6. **Login próprio do Cursor para o curador** (abordagem A). Recomendo; se o R2 mostrar que não funciona, B com
   Seatbelt.
7. **Prompt do Cursor em argv se não houver stdin**: recomendo aceitar só para o Cursor, documentado (agentes do mesmo
   usuário já leem as transcrições do Claude no modo strict), em vez de deixar o Cursor fora.
8. **Modelo do Cursor**: recomendo não passar `--model` (padrão da conta) até o dono escolher na lista.

## Riscos

- O Cursor é um agente com ferramentas; a contenção é em camadas (ask, config fechada, HOME própria, Seatbelt) e
  depende do R4 (texto hostil).
- Sem schema, um modelo pode responder texto; a pausa e o fail-closed seguram, mas a memória aprende menos.
- `AGENT_CLI_CREDENTIAL_STORE=file` e o login em HOME própria não foram testados (R2).
- `-p` já travou em versões passadas; o timeout e o `.exhausted` são o freio.
- Cobrança por uso do plano do Cursor é invisível para o Collie.
- O perfil `deny default` pode quebrar o Claude por um caminho esquecido (R2 antes de ligar).

## Fica para depois (desenhado, não entregue)

- **Codex**: `codex exec --output-schema -o --json --ephemeral`, `-c features.shell_tool=false`,
  `web_search="disabled"`, `CODEX_HOME` próprio (o `AGENTS.md` global entra em toda execução), `login status` sem
  token. Fontes: <https://learn.chatgpt.com/docs/non-interactive-mode>,
  <https://learn.chatgpt.com/docs/config-file/config-basic.md>.
- **Ollama/LM Studio**: Ollama `/api/chat` com `format` e `num_ctx` (contexto padrão 4096; pela API OpenAI não muda),
  sem autenticação (precisa conferir o dono do socket, bloquear redirect/proxy, fixar o digest do modelo,
  `disable_ollama_cloud`). LM Studio fixa contexto ao carregar e tem `lms link` remoto. Fontes:
  <https://docs.ollama.com/context-length>, <https://docs.ollama.com/faq>.
- **Apple Intelligence**: 4096 tokens para tudo e macOS 26; só jobs pequenos. Fonte:
  <https://developer.apple.com/documentation/foundationmodels/managing-the-context-window>.
- **Chave de API**: só opt-in, Keychain, teto em dólar (R5).
- Qualquer provedor novo (Codex incluso) entra implementando `CuratorRunner`, inclusive `billing()`; a política de
  cobrança do `Curator` vale para ele sem mudança.

## Tarefas (lista; o plano detalha)

1. Docs ASM/ciclo de vida. 2. Veredito fail-closed (E1). 3. Config tolerante (E7). 4. Origem nos registros (E2).
5. Perfil Seatbelt dedicado (E5; **R2**). 6. stdin e `.exhausted` (E4, E6). 7. Método de login do Claude (E3; **R1**).
8. Provedores no `Curator`. 9. Resultado do job, pausa, `inputMax`. 10. Confiança limitada. 11. `CursorCuratorRunner`
(**R2, R3**). 12. Comando, status, consentimento. 13. Preferências e painel. Roteiro manual R1–R6.
