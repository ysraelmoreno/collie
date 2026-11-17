# Provedor do curador de memória — design

Status: rascunho para o dono revisar (2026-11-17), revisado (revisão independente aplicada em 2026-11-17: B1–B5,
I1–I13, M1–M10 e afirmações falsas; discordâncias em “Notas da revisão”). Nada implementado. Pedidos: ask d22440b8 e
bd97401f do Collie Main. Plano: `docs/superpowers/plans/2026-11-17-curator-provider.md`.

## Intenção e porquê

O curador é o modelo headless que organiza a memória do Collie: julga correções, ativa ou descarta propostas,
lê conversas, junta duplicatas, confere memórias contestadas, propõe procedimentos e indexa documentos. Hoje ele
**só** roda como `claude -p` no login do Claude. Quem não tem assinatura Claude fica sem curador e, na prática, sem
a parte da memória que aprende sozinha. O dono quer poder **escolher e trocar** o agente que cura.

Fracasso mesmo funcionando: gastar token do usuário em silêncio (chave de API, cobrança por uso); mandar trechos de
conversa para uma empresa nova sem o usuário saber; um modelo fraco ativar, apagar ou reescrever memórias; um texto
injetado nos dados fazer um agente com ferramentas ler credenciais ou escrever fora do cwd; um processo qualquer do
Mac se passar pelo “modelo local”; perder fila, histórico ou ciclo de vida na troca; testes que gastam token ou abrem
rede.

## Estado atual (verificado no código, main em aa4427a)

### O curador

- `CuratorRunner` (`Curator/CuratorRunner.swift:26-29`) já é o ponto de troca: `availability()` e
  `run(call, model:, timeout:)`. Única implementação `ClaudeCuratorRunner`, escolhida em `CommandRouter.swift:249-250`
  (`config.curatorRunner ?? ClaudeCuratorRunner(...)`; testes injetam `FakeCurator`, `Daemon.swift:123-124`).
- `ClaudeCuratorRunner`: `claude -p` com `--tools ""`, MCP vazio estrito, `--setting-sources project,local`,
  `--safe-mode`, sem slash commands, sem sessão, `--permission-prompts none`, `--max-budget-usd 0.05`,
  `--json-schema`, `--system-prompt` e **o input em argv** (`CuratorRunner.swift:68-73`); cwd temporário vazio 0700;
  ambiente do usuário sem `COLLIE_*` nem `ANTHROPIC_API_KEY/AUTH_TOKEN/BASE_URL`, `CLAUDE_CODE_USE_BEDROCK/VERTEX`
  (R5, `:50-51`, `:114-117`); `HOME` = `config.sandboxHome ?? home real` (`CommandRouter.swift:168`): em produção, a
  home real. Parse de `structured_output`/`result` em `:78-104`.
- **Disponibilidade só olha `loggedIn`** (`:136-155`): um login de Console (cobrado por uso) passa como “plano”. A
  regra R5 hoje cobre chaves no ambiente, não o método de login.
- **Sandbox**: perfil do *terminal* em modo strict com `agent: .claude`, um id fixo `…c0de` e um arquivo fixo
  `curator/curator.sb` (`:34`, `:161-180`). O modo strict **lê o disco inteiro** menos `readClosed`
  (`SandboxProfile.swift:135-141`); `homeWrites` vale para qualquer agente e inclui `~/.claude.json*` (R13, plantar
  MCP global aceito para terminais), `Library/Keychains` (R12), `.claude/.credentials.json*` e `.codex/auth.json`
  (`EssentialPaths.swift:22-29`, `SandboxProfile.swift:149`); rede liberada (`(allow default)`, `:104`, só nega
  sockets Unix do Collie, `:229-230`); `/bin/ps` roda sem sandbox (`:237`). Para o Claude sem ferramentas isso pesa
  pouco; para um provedor com shell, não serve.
- `Curator` (`Curator.swift`): fila durável em `~/Library/Application Support/Collie/curator/jobs/`, um job por vez
  por prioridade (`:8-11`), tick de 10 min, 3 tentativas e `failed/`, fila máxima 200 (`:48`; cheia, recusa, e uma
  correção expulsa o job de propostas mais antigo, `:127-131`), entrada cortada **pelo fim** em 12 000 escalares
  (`:45`, `:265-268`), timeout fixo 60 s (`:46`). `Config { cap = 40; model = "haiku" }` com `Codable` sintetizado em
  `curator/config.json` (`:51`, `:81`): chave nova não opcional quebra a leitura e volta tudo ao padrão; o `setCap`
  regrava o arquivo inteiro (`:149-151`). Nenhum comando muda o modelo. `curator/` não entra no `.colliebackup`
  (`DataBackup.swift:17`).
- Erros: `.unavailable` vindo do `run` vira `.internal` e **gasta tentativa** (`:280-282`). Um “cota acabou” ou
  “sem crédito” (`is_error`, `CuratorRunner.swift:95`) leva cada job a `failed/` em 3 rodadas.
- Evento `curatorRun` (`Curator.swift:272-283`; campos em `MemoryEvents.swift:23-26`); `model` só para
  `sessionUsage` (`:27-28`). Consumidos em `MemoryObservability.swift:126-188`.
- `memory.curator` está em `memoryReads` (não muda registro, `MemoryCommands.swift:12-13`) e é **admin-only** de
  verdade (`MemoryCommands.swift:42-47`, `CommandRouter.swift:347-361`).

### Validação e fence

- Três formatos de saída, cada um com seu parser:
  - `{"ops":[…]}` com `CuratorOps.validate` (`CuratorOps.swift:75-80`): correção, propostas, pitfall, consolidação,
    verificação, procedimento (`ProcedureDetector.swift:163-164`, só o primeiro `create`).
  - `{"items":[…]}` da conversa (`ConversationCapture.swift:30-45`, `decode` `:62-65`, `apply` `:73-95`).
  - `{"chunks":[…]}` do docTerms (`DocTerms.swift:28-38`, `parse`).
- `validate` nunca lança: lixo vira `([], 1)`; os handlers não devolvem esse `dropped` ao `Curator`.
- Fence `DADOS-<nonce>` (32 hex por job) e `DADOS-` do dado reescrito para `DADOS_` (`MemoryLearning.swift:65-79`;
  mesmo molde em `MemoryVerify`, `ConversationCapture:49-61`, `DocTerms:46-53`, `Consolidation`, `PitfallClasses`,
  `ProcedureDetector`). Os builders dimensionam pelo `Curator.inputMax` estático (`ConversationCapture.swift:59`,
  `:195`; `Consolidation.swift:166`, ao enfileirar); o fence de fechamento só sobrevive porque o builder já cabe.
- Segredos: `LotBoards.scrub` (`Lots/LotBoard.swift:161-173`) na entrada; só formatos marcados.

### Fraquezas que já existem com o Claude (independentes de provedor)

- **E1. Verificação falha aberta**: `applyVerdict` (`Memory/MemoryService.swift`, `func applyVerdict`) trata como
  `invalid` só um `retire` daquele id; **qualquer outra saída**, inclusive `{}` ou lixo, é “valid”: limpa flags e
  contestação (`verifyContested`) ou promove a longTerm (`verifyPromotion`). `runVerifyJob`
  (`MemoryVerify.swift:102-120`) descarta o `dropped`.
- **E2. Origem não decide nada**: a conversa grava `decision`/`pitfall` como `.active` (`ConversationCapture.swift:89`),
  fora do `applyOps`; a ativação de 14 dias (`LifecyclePass.swift:76-87`) ativa qualquer proposta de projeto não
  revisada com claims ok, sem olhar quem a criou. `origin` é só um texto (`"conversa (…)"`, `"curador (trabalhos)"`).
- **E3. Login do plano não verificado** (acima).
- **E4. Prompt em argv**: outros processos (inclusive agentes, via `/bin/ps` sem sandbox) leem trechos enquanto o
  curador roda.
- **E5. Perfil do curador é o do terminal** (acima).
- **E6. Cota/crédito esgotado manda jobs para `failed/`** (acima).
- **E7. `config.json` sem migração** (acima).

### Os jobs e o que acontece sem curador

Sem curador (runner indisponível, limite 0 ou atingido) a fila **espera** (`Curator.swift:224`, `:230-232`). Com a
fila cheia, novos jobs são recusados (só correção entra, expulsando propostas). Job que falha 3 vezes vai para
`failed/`.

| Job | Quem enfileira | Saída | Sem curador |
|---|---|---|---|
| `correction` | hook UserPromptSubmit (`MemoryCommands.swift:238-242`) | ops | citação já salva como `proposed` (`MemoryLearning.swift:147-153`); revisar à mão cancela o job |
| `verifyContested` | `memory flag`, checagem de claim | ops (só `retire`) | checagem objetiva falhou → arquiva reversível; senão “deferred”; 14 dias → “Precisa de você” (`MemoryVerify.swift:80-93`, `LifecyclePass.swift:92-107`) |
| `verifyPromotion` | ciclo de vida passo 3 (`LifecyclePass.swift:34-38`) | ops | nunca promove |
| `proposals` | captura de trabalho, migração | ops | ficam `proposed`; enquanto na fila não expiram |
| `pitfall` | save/captura de pitfall, revisões | ops | mesma classe por assunto somada sem modelo (`PitfallClasses.swift:144-151`) |
| `conversation` | 10 min ociosos após Stop, compactação, fim | items | nada capturado; a marca não anda. Só transcrições do Claude (`ConversationCapture.swift:265`) |
| `consolidate` | tarefa diária, `memory consolidate` | ops | limpeza determinística e ciclo de vida rodam (`Consolidation.swift:136-155`) |
| `procedure` | detector de sequências | ops | nenhum proposto |
| `docTerms` | `memory doc-add` | chunks | busca por palavras + NLEmbedding; **sem digest nem undo** quando roda |

Roda sempre sem curador: save, search (FTS + `NLEmbedding`), context, checklist, injeção nos hooks, doc-add/search,
list/get/review/promote/supersede/restore/pin/flag, cleanup/purge/undo, ciclo de vida inteiro e skills.

### O que o usuário vê

- Painel Memória (`ColliePlugins/MemoryPanel.swift:175-180`, `:416-424`): “curador indisponível: <motivo>” ou
  “Curador: 12/40 hoje · 18 mil tokens · US$ 0,04”; Stepper “Limite diário”. `CuratorInfo` exige `costUSD: Double`
  (`:47-49`).
- Observabilidade (`MemoryObservability.swift:71-75`): “Curador falhando…”, “Fila do curador parada…”.
- CLI `collie memory curator [--cap N]`, `memory digest` (JSON; `Commands.swift:263-266`).
- Preferências › Memória: só dois toggles (`PreferencesView.swift:262-268`).

### Outros fatos

- Modelo local já existe: `FoundationLocalModel` (`Work/LocalModel.swift`), só no `WorkAssistant`; `respond` devolve
  `String` (`:13-16`); macOS 26 + Apple Intelligence; **esta máquina roda macOS 15.6.1**.
- Specs vizinhos dizem que o curador é “o modelo on-device” (`2026-11-15-asm-design.md:64`,
  `2026-11-13-memory-lifecycle-design.md:38`): errado, é `claude -p`.
- PATH do daemon vem de `$SHELL -ilc` (`UserEnvironment.swift:3-17`): acha binários de brew/nvm.
- CLIs aqui (só `--help`/`--version`): `claude` 2.1.326 (flags do curador presentes); `codex` **não instalado**;
  `cursor-agent` 2026.11.13-eacade1; `ollama` 0.40.16; `lms` (tem `link`, instâncias remotas).

## Provedores candidatos

### Codex CLI (`codex exec`)

Fontes: <https://learn.chatgpt.com/docs/non-interactive-mode>,
<https://learn.chatgpt.com/docs/developer-commands?surface=cli>,
<https://learn.chatgpt.com/docs/config-file/config-basic.md>,
<https://learn.chatgpt.com/docs/agent-configuration/agents-md>.

- `--output-schema <arquivo>`, `-o/--output-last-message <arquivo>`, `--json` (JSONL; `turn.completed.usage
  {input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens}`, `turn.failed`, `error`),
  `--ephemeral`, `--skip-git-repo-check`, `--ignore-user-config` (autenticação continua em `CODEX_HOME`),
  `--ignore-rules`, `-s read-only`, `-C`, `-m`, `-c k=v`, `--disable <feature>` (= `-c features.<nome>=false`).
- **Shell desligável**: feature `shell_tool` (“Enable command execution tools”, padrão true) →
  `-c features.shell_tool=false`; busca → `-c web_search="disabled"`; `memories` (padrão false) → forçar false.
- Contexto do usuário: o `AGENTS.md` (ou `AGENTS.override.md`) de `CODEX_HOME` entra em toda execução; não há
  chave documentada para desligar; `--ignore-user-config` não é citado como removendo. `~/.codex/` aqui tem
  `agents/`, `memories/`, `skills/`.
- Autenticação: login salvo em `CODEX_HOME/auth.json` (o refresh grava nele); `CODEX_API_KEY`/`OPENAI_API_KEY`
  trocam para chave. `codex login status` imprime o modo e sai 0 logado (formato do modo chave não documentado).
- Não documentado (fixture e passo do dono): códigos de saída, modelo padrão, rate limit do plano em `exec`, se
  `read-only` corta rede, comportamento dentro de outro `sandbox-exec`.

### Cursor (`cursor-agent -p`)

`--help` local e <https://cursor.com/docs/cli/reference/output-format>: `-p` “has access to all tools, including
write and shell”; `--mode ask`, `--sandbox enabled`; JSON `{type, subtype, is_error, result, duration_ms,
session_id}`, sem `usage`; erro → stderr e saída ≠ 0; sem schema; `CURSOR_API_KEY`, `CURSOR_API_ENDPOINT`, `-H`
mudam conta/destino. Depois da v1.

### Ollama (API nativa)

Fontes: <https://docs.ollama.com/capabilities/structured-outputs>, <https://docs.ollama.com/api/openai-compatibility>,
<https://docs.ollama.com/context-length>, <https://docs.ollama.com/faq>, <https://docs.ollama.com/cloud>.

- `/api/chat` em `127.0.0.1:11434` com `format: <JSON Schema>`, `options` (`num_ctx`, `temperature`), `keep_alive`.
- **Contexto padrão 4096 tokens** abaixo de 24 GiB de VRAM (quase todo Mac); pela API compatível com OpenAI não dá
  para mudar. Entrada maior é truncada pelo servidor. Por isso a API **nativa**, com `num_ctx` explícito.
- **Sem autenticação** (“Ollama ignores it”): qualquer processo do Mac chama `/api/create`/`/api/copy` e troca o
  modelo; qualquer processo pode escutar em 11434 com o Ollama parado.
- Nuvem: `signin`/modelos de nuvem; modo só local documentado: `OLLAMA_NO_CLOUD=1` ou
  `"disable_ollama_cloud": true` em `~/.ollama/server.json`. A nuvem não suporta saída estruturada. A convenção
  `:cloud` no nome **não** é documentada como regra.
- Modelo sai da memória após 5 min por padrão (`keep_alive` por requisição muda).

### LM Studio

API compatível com OpenAI em `localhost:1234/v1` com `json_schema`
(<https://lmstudio.ai/docs/developer/openai-compat/structured-output>, que avisa sobre modelos < 7B); contexto é
fixado ao carregar o modelo; `lms link` repassa para instâncias remotas. Depois da v1 (ver Abordagens).

### Apple Intelligence (FoundationModels)

Sem conta nem rede, mas macOS 26 e **4096 tokens para tudo** (instruções, schema, entrada, saída;
<https://developer.apple.com/documentation/foundationmodels/managing-the-context-window>, TN3193; `contextSize` só no
26.4). Só serve a jobs pequenos com orçamento próprio. Depois da v1.

### Chave de API

Contraria R5 se automática. Só opt-in explícito, Keychain, teto em dólar. Fora da v1.

## Metas

1. Escolher provedor (Claude, Codex, Ollama) e modelo, por Mac, nas Preferências e na CLI admin.
2. Mesma fila, prompts, fence e validação para todos; um provedor fraco não ativa, apaga nem reescreve memória sozinho.
3. Nenhum provedor gasta token por chave ou login cobrado por uso sem o usuário ligar.
4. Antes de ligar um provedor de nuvem, o usuário vê para onde vão os dados.
5. “Testar agora” sem gastar token; “Testar com uma chamada” com custo mostrado e confirmação.
6. Troca sem perder fila, digest, ciclo de vida nem estatísticas; eventos dizem provedor e modelo.
7. Quem não tem Claude recebe uma sugestão do que está instalado.
8. Testes com fakes e fixtures, sem rede nem token.

## Não metas

- Cursor, LM Studio, Apple e chave de API na v1 (desenhados, entregues depois).
- Servidor de modelo fora do loopback.
- Provedor por repositório/cercado ou por espaço ASM.
- Capturar conversas de Codex/Cursor.
- Mudar prompts, schemas de job ou prioridades.
- Fazer backup de `curator/` (restaurar volta ao padrão Claude, o lado seguro).

## Abordagens

### A. Interface única; correções de segurança primeiro; v1 = Codex + Ollama (recomendada)

Endurecer o curador atual (E1–E7), depois a camada de provedor e confiança, depois Codex (o caso “tenho ChatGPT,
não Claude”) e Ollama (“não tenho assinatura” e privacidade). Cursor, LM Studio, Apple e chave por cima da mesma
interface.

### B. Só chave de API

Simples e com custo exato, mas cobra por token, contraria R5 e deixa sem curador quem não tem chave.

### C. “Qualquer comando” configurável

Impossível de sandboxear, pinar, parsear e testar; vira injeção com ferramentas. Descartada.

Apple como principal (o que os specs ASM/ciclo de vida supunham) não cabe em 4096 tokens nem roda no macOS 15.
Ollama antes de LM Studio: API nativa com `num_ctx` e `format`, modo só local verificável (`server.json`), um binário
só para conferir o dono do socket.

## Design

### 0. O que vem antes e por quê

Duas camadas, nesta ordem:

**Correções do estado atual** (valem para o Claude hoje):
E1 verificação fail-closed; E2 origem e confiança em cada registro; E5 perfil Seatbelt dedicado do curador;
E7 `config.json` com migração nos dois sentidos; E3 método de login; E4 prompt por stdin; E6 erro de cota não gasta
tentativa.

**Pré-requisitos do multi-provedor**: provedor e confiança (§1–2), resultado do handler ao `Curator` (§2.4),
`inputMax` do provedor nos builders (§2.5), runner local endurecido (§4), Codex sem shell e com `CODEX_HOME` próprio
(§3).

Recomendação: **E1, E2, E5 e E7 antes de qualquer provedor novo**, E1 primeiro (está aberto hoje com o Claude: um
`{}` limpa uma contestação). Um provedor mais fraco amplifica exatamente essas quatro (veredito, ativação, sandbox,
config). E3, E4 e E6 são baratos e entram na mesma leva, mas não bloqueiam.

### 1. Interface

```swift
enum CuratorProvider: String, Codable, CaseIterable, Sendable { case claude, codex, ollama }   // depois: cursor, lmstudio, apple, apiKey
enum CuratorTrust: String, Codable, Sendable { case full, limited }   // claude, codex: full; ollama (e apple, lmstudio): limited

struct CuratorProviderInfo: Codable, Sendable {
    var provider: CuratorProvider
    var trust: CuratorTrust
    var destination: String       // "Anthropic", "OpenAI", "este Mac"
    var reportsCost: Bool         // só claude
    var timeout: Duration         // medido na fixture: claude 60 s; codex e ollama definidos na tarefa do runner
    var inputMax: Int             // escalares; claude/codex 12 000; ollama derivado de num_ctx
}

protocol CuratorRunner: Sendable {
    var info: CuratorProviderInfo { get }
    func availability() async -> CuratorAvailability        // sem token; cache 600 s (resposta real) / 30 s (falha)
    func models() async -> [String]                         // [] = texto livre
    func run(_ c: CuratorCall, model: String, timeout: Duration) async throws(ProtocolError) -> CuratorOutput
}
```

- `CuratorOutput.costUSD: Double?` (nil = plano/local/desconhecido) e `CuratorOutput.provider/model`.
  `CuratorStatus.costUSD` **continua `Double`** (soma; o app antigo exige). Evento `curatorRun`: `costUSD` opcional
  (já é), `provider` novo, `model` preenchido.
- `CuratorAvailability` ganha `.exhausted(String, until: Date?)` para cota/crédito/rate limit (E6): o `Curator` não
  gasta tentativa e mostra o motivo; o cache do runner guarda até `until` (ou 30 min).
- `Curator` recebe `[CuratorProvider: any CuratorRunner]`; `DaemonConfig.curatorRunners` injeta fakes; o
  `curatorRunner` atual vira atalho para “só este provedor”.
- **Config** (E7), decodificação manual com `decodeIfPresent` e padrão por campo:
  `{ cap, model, provider = "claude", models: {provider: modelo}, ollama: {url, numCtx, modelDigest}, consented:
  [provider] }`. `model` continua gravado com o modelo do Claude. Um daemon antigo que regrave o arquivo (`setCap`)
  apaga `provider`/`consented` e o novo volta a Claude sem consentimento extra: falha no lado seguro. Teste nos dois
  sentidos.
- `memory.curator` ganha `provider`, `model`, `ollamaURL`, `numCtx`, `consent`, `test`, `testCall` — herda o
  admin-only; fica em `memoryReads` (não muda registro de memória).
- Sandbox id e arquivo de perfil **por chamada** (`curator/<provider>-<uuid>.sb`, apagado no fim) para “testar” não
  sobrescrever um job em andamento.

### 2. Validação, confiança e portão de qualidade

#### 2.1 Origem em cada registro (E2)

`MemoryRecord` ganha `curatedBy: {provider, model, trust}?` em todo registro que o curador cria, ativa, junta ou
reescreve (nil = usuário/agente/determinístico, como hoje). Gravado por `applyOps` e pelo `apply` da conversa.

#### 2.2 Veredito fail-closed (E1)

- `runVerifyJob` exige `{"ops":[…]}` legível **e** `dropped == 0`; senão o job **falha** (gasta tentativa), nunca é
  “valid”.
- `applyVerdict` recebe um veredito explícito `.invalid | .valid | .undecided`. `{"ops":[]}` = valid (o schema e o
  prompt já dizem que vazio é “nada a mudar”); qualquer outra coisa sem `retire` do id = undecided (não limpa nada,
  não promove).

#### 2.3 Confiança limitada (`trust == .limited`)

| Caminho | Full (hoje) | Limited |
|---|---|---|
| `create` (ops) | active/proposed conforme job | sempre `proposed` |
| conversa `decision`/`pitfall` | `active` | `proposed` |
| `activate` | aplica | vira `ask` em “Precisa de você” |
| `retire`, `drop`, `supersede`, `merge`, `score` < 0 | aplica | vira `ask` com o motivo do modelo |
| `bump` de pitfall, `score` > 0 | aplica | aplica |
| `verifyContested` valid | limpa contestação | não limpa; só arquiva se a checagem objetiva falhou (caminho sem modelo) |
| `verifyPromotion` | promove | **não é enfileirado** (gate em `enqueuePromotion`) |
| ativação de 14 dias | ativa | registros com `curatedBy.trust == .limited` ficam de fora |
| docTerms | grava termos | grava termos (só ranking de busca; sem undo, como hoje), marcados com o provedor |
| ASM classificar para espaço | conforme spec ASM | sempre `none` |

#### 2.4 Resultado do job e pausa por saída ruim

- Cada handler devolve ao `Curator` um `CuratorJobResult { ok | junk | allDropped }` (ops: pelo `dropped` do
  `validate`; items/chunks: pelo `decode`/`parse`). `{"ops":[]}`, `{"items":[]}` e `{"chunks":[]}` são `ok`.
- Janela das últimas 20 chamadas do provedor ativo: ≥ 10 `junk`/`allDropped` → provedor indisponível com “saída
  inválida em N de 20 (troque de modelo)”. Jobs esperam. Trocar de modelo ou “Testar com uma chamada” bem-sucedido
  zera a janela.

#### 2.5 Schema e entrada por provedor

- Transformação para schema estrito (todas as propriedades em `required`, opcionais com `null`) nos três schemas
  (`ops`, `items`, `chunks`), com teste de cada um e de que `validate`/`decode`/`parse` tratam `null` como ausente.
- `inputMax` do provedor ativo é passado aos builders **na execução** (conversa, consolidação, verificação,
  docTerms); se o dado não cabe, o builder recorta **dentro** do fence. O corte final do `Curator.call` vira só um
  assert de segurança: entrada acima do limite = job falha, nunca string cortada.
- Ollama: `inputMax` derivado de `num_ctx` (tokens estimados por `scalars / 3` menos instruções, schema e saída
  reservada); se não couber nem um mínimo útil, provedor indisponível com “contexto pequeno demais (num_ctx N)”.

#### 2.6 Desfazer

Tudo que o curador aplica em registros continua no digest com `memory.undo`. docTerms não tem digest (só termos de
busca); trocar de provedor não reprocessa termos antigos.

### 3. Codex

Chamada (pinar no `codex exec --help` e `codex features list` da versão do dono):

```
sandbox-exec -f <perfil do curador> codex exec - \
  --json --ephemeral --skip-git-repo-check --ignore-user-config --ignore-rules --sandbox read-only --color never \
  -C <cwd vazio> --output-schema <cwd>/schema.json -o <cwd>/out.json [-m <modelo>] \
  -c features.shell_tool=false -c web_search="disabled" -c features.memories=false \
  -c model_reasoning_effort="low"          # prompt (instruções + dados fenced) pelo stdin
```

- **Sem shell, sem busca**: antes de cada uso (com o cache da disponibilidade), `codex features list` com os mesmos
  `-c`; se `shell_tool` não aparecer desligado, provedor indisponível (“codex sem como desligar o shell nesta versão”).
- **`CODEX_HOME` próprio** em `<root>/curator/codex-home/` (0700): sem `AGENTS.md`, skills nem memories do usuário.
  Login próprio do curador, feito pelo usuário uma vez pelas Preferências (“Entrar no Codex para o curador”, abre
  `CODEX_HOME=… codex login` num terminal do Collie). Não se copia nem se liga o `auth.json` do usuário: o refresh
  rotaciona o token e um dos lados quebraria.
- Ambiente: usuário menos `COLLIE_*`, `OPENAI_API_KEY`, `CODEX_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_ORG_ID`,
  `OPENAI_PROJECT_ID`; `CODEX_HOME` o dedicado.
- `codex login status`: só o modo ChatGPT conta como disponível; modo chave → “codex logado por chave de API (cobrança
  por token)”. Fixture de cada modo (passo do dono).
- Cota/rate limit (`turn.failed`/`error` com o texto do limite) → `.exhausted`.
- Saída: só `out.json`; o JSONL para `usage` e erro.
- Timeout: medido na fixture com `low`; ponto de partida 120 s.

### 4. Ollama

- Chamada do próprio daemon (`URLSession` efêmera): `POST /api/chat` com `stream: false`, `format: <schema>`,
  `options: {num_ctx, temperature: 0}`, `keep_alive: "15m"` (cobre o tick de 10 min), sem `tools`.
- **Sem redirect** (delegate devolve nil) e **sem proxy** (`connectionProxyDictionary = [:]`); host só
  `127.0.0.1`/`::1` (nunca resolver `localhost` por DNS).
- **Dono do socket**: antes de cada chamada, achar o processo que escuta na porta (libproc: `proc_listpids` +
  `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`), conferir uid == usuário e o binário assinado pelo time do Ollama
  (`SecStaticCode`, requisito com o Team ID gravado na primeira confirmação). Diferente → indisponível (“outro
  programa está na porta 11434”).
- **Modelo fixado**: no consentimento grava o `digest` do modelo (`/api/tags`); digest diferente depois →
  indisponível (“o modelo mudou; confirme nas Preferências”).
- **Nuvem**: lê `~/.ollama/server.json`; sem `disable_ollama_cloud: true` (e sem `OLLAMA_NO_CLOUD` no ambiente do
  servidor, quando dá para saber) a Preferência mostra “o Ollama pode mandar pedidos à nuvem; ligue o modo só local” e
  o consentimento cita isso. Nome `:cloud`/`-cloud` é recusado como reforço, não como garantia.
- Usage: `prompt_eval_count`/`eval_count` (fixture); custo nil.
- Disponibilidade com o mesmo cache 600 s / 30 s.

### 5. Perfil Seatbelt dedicado do curador (E5)

Novo `CuratorSandboxProfile` (não reusa o do terminal):

- `(deny default)` com o mínimo: `process-exec` só do binário do provedor (e `/usr/bin/env`/node se o pacote for um
  launcher, a pinar), leitura de `/System`, `/usr/lib`, `/usr/share`, `/private/var/db/dyld`, o binário e sua pasta,
  o cwd, o estado do provedor (`~/.claude` para o Claude; `<root>/curator/codex-home` para o Codex) e o que o
  sistema precisa (`/dev/null`, `/dev/urandom`, resolvers, certificados); escrita só no cwd e no estado do provedor
  (no Claude: `.claude/.credentials.json*`, `.claude.json*` só se a CLI exigir — a pinar; no Codex: `codex-home`).
- **Sem `homeWrites`**, sem `Library/Keychains` de escrita, sem `/bin/ps` sem sandbox, sem sockets Unix.
- Rede: liberada para Claude/Codex (precisam da API; Seatbelt não filtra por host); Ollama não usa subprocesso.
- Testes do perfil renderizado: `~/.claude.json` (Codex), `~/.ssh`, `~/.config/gh`, `~/.codex/auth.json` do
  usuário, `Library/Keychains` e um repositório qualquer negados; cwd e estado do provedor liberados.
- Sandbox aninhado (o Codex aplica o próprio `sandbox-exec` para comandos): com `shell_tool=false` não há comando;
  ainda assim é passo manual do dono confirmar que o Codex roda dentro do perfil.

### 6. Segurança e privacidade (resumo)

| Provedor | Sai do Mac | Credencial | Barreiras |
|---|---|---|---|
| Claude | dados fenced + instruções → Anthropic | login Claude (método conferido, E3) | sem tools, perfil dedicado, stdin |
| Codex | o mesmo → OpenAI | login ChatGPT no `CODEX_HOME` do curador | sem shell/busca, perfil dedicado, stdin |
| Ollama | nada, em modo só local | nenhuma | loopback, sem redirect/proxy, dono do socket, digest |

- **Aviso antes de ligar** um provedor de nuvem: “O curador lê trechos das suas conversas, documentos e memórias deste
  Mac e os envia a <destino>, sob os termos do seu plano. Nada é enviado por chave de API.” Para Ollama: “Nada sai
  deste Mac se o Ollama estiver em modo só local” + o estado lido. Confirmar grava `consented`. Sem consentimento o
  provedor é indisponível (“falta confirmar nas Preferências”). Claude atual: consentimento implícito.
- **E3**: o `auth status --json` do Claude é lido também pelo método de login (fixture de assinatura e de Console;
  passo do dono gravar). Console/chave → “claude logado por conta de API (cobrança por token)”.
- **E4**: prompt por stdin no Claude (`claude -p` lê stdin; pinar) e no Codex (`codex exec -`).
- `LotBoards.scrub` continua antes do fence para todos.

### 7. UX

```
Curador da memória
  Provedor   [ Claude ▾ ]   ● disponível · dados vão para Anthropic
             Claude · Codex (entrar…) · Ollama (127.0.0.1:11434, só local) · Desligado
  Modelo     [ haiku ▾ ]     (Ollama: lista de /api/tags; Codex: texto livre, vazio = padrão da CLI)
  Contexto   [ 8192 ] tokens (só Ollama; num_ctx)
  Limite     [ 40 ] jobs por dia
  [ Testar agora ]  → "Ollama 0.x · modelo fixado · só local · sem custo"   [ Testar com uma chamada… ]
  Confiança limitada: criar vira proposta; ativar, apagar ou reescrever vira pergunta.   (só Ollama)
```

- **Testar agora**: `availability()` + `models()`, zero token. **Testar com uma chamada**: um job sintético por
  formato (ops, items, chunks) de poucas linhas, conta 1 job cada no limite, mostra tokens/custo e o
  `CuratorJobResult`; confirmação antes.
- **Detecção** sem gastar: `claude`, `codex`, `cursor-agent` no PATH; Ollama só se o dono do socket passar.
- **Sem Claude**: “curador indisponível: claude não encontrado · Codex instalado: [Configurar]”. Nunca troca sozinho.
- **Provedor some**: motivo com o nome do provedor, jobs esperam, sugestão de outro detectado.
- **Troca**: muda `config.provider`; o job em andamento termina no antigo; fila, digest, ciclo de vida, `usage.json`
  e eventos ficam (agregados por provedor).
- Linha do painel: Claude como hoje; Codex “12/40 hoje · 18 mil tokens · plano”; Ollama “12/40 hoje · local, sem
  custo”; `.exhausted`: “cota do <provedor> esgotada até HH:MM”; lento: “curador lento (mediana X s)”.

### 8. Migração e compatibilidade

- Configuração **por Mac** (`<root>/curator/config.json`).
- **ASM**: cada Mac cura os próprios candidatos (`asm-design.md:90-94`, `:161-170`); provedor por pessoa. Limitado →
  classificação `none` (só `--space` explícito sobe). Política por espaço fica fora.
- **Daemon antigo + app novo**: `provider` ausente no status → seção desabilitada (“reinicie o serviço para usar
  isto”). **App antigo + daemon novo**: campos extras ignorados; `costUSD` continua `Double`. **Downgrade do
  daemon**: lê `cap`/`model` e ignora o resto; se regravar, o novo volta a Claude (E7).
- Registros sem `curatedBy` = como hoje. Jobs da fila não mudam de formato.

### 9. Custos, limites e lentidão

- Limite em jobs por dia, um número (o quarto das correções vale para todos). Padrão 40 para todos até medir
  duração e consumo de um modelo local (200 jobs × minutos de GPU num notebook pesa em bateria e temperatura).
- Claude: `--max-budget-usd 0.05` por chamada. Codex: limite de jobs + entrada + timeout + `.exhausted`. Ollama: sem
  custo.
- Fila um job por vez; provedor lento só reduz vazão; correções na frente; timeout gasta tentativa.
- Fila cheia (200): enfileirar recusa; com limitado, `verifyPromotion` nem entra (§2.3).

### 10. Testes

- `FakeCurator` ganha `info` e resultado configuráveis.
- Correções: `VerifyJobTests` (lixo e `{}` nunca viram valid; `{"ops":[]}` é valid), `CuratorConfigTests`
  (migração nos dois sentidos), `CuratorSandboxProfileTests` (negações), `CuratorRunnerTests` (método de login,
  stdin, `.exhausted`), `LifecyclePassTests`/`ConversationApplyTests` (origem limitada).
- Provedores: `CodexCuratorRunnerTests` (argumentos, stdin, `features list`, `login status`, JSONL, ambiente,
  `CODEX_HOME`), `OllamaCuratorRunnerTests` (`URLProtocol` stub: redirect recusado, proxy ignorado, host não
  loopback recusado, digest, `server.json`, `num_ctx`/`inputMax`; dono do socket por função injetada),
  `CuratorProviderTests` (troca, eventos, pausa, confiança), `CuratorSchemaTests` (estrito × 3).
- Só `swift test --filter`; nada chama `claude`, `codex`, `ollama`, `lms` reais nem abre socket.
- Só à mão (roteiro do dono): Codex real e `features list`, sandbox aninhado, prompt hostil (red team) no Codex e no
  Ollama, aparência de um modelo de nuvem em `/api/tags`/`/api/show`, fixtures de `auth status`/`login status`.

## Decisões

- Abordagem A; correções E1, E2, E5, E7 antes de qualquer provedor; E1 primeiro.
- v1 = Claude (endurecido) + Codex + Ollama (API nativa); depois Cursor, LM Studio, Apple, chave.
- Origem `curatedBy` em todo registro curado; confiança limitada para modelos locais (tabela §2.3).
- Veredito explícito; lixo nunca é “valid”.
- Perfil Seatbelt dedicado por chamada; sem `homeWrites`.
- Codex sem shell/busca/memories, `CODEX_HOME` próprio com login próprio, prompt por stdin.
- Ollama: loopback literal, sem redirect/proxy, dono do socket assinado, digest fixado, estado “só local” mostrado.
- Config por Mac, decodificação tolerante, `costUSD` do status `Double`.
- Consentimento explícito por provedor novo; nunca troca automática.

## Minhas chamadas (conferir)

1. **Codex antes de Cursor** (schema e usage; Cursor não tem).
2. **Ollama antes de LM Studio e Apple** (num_ctx nativo, modo só local verificável; Apple 4096 tokens/macOS 26).
3. **Confiança limitada** como na tabela §2.3. Alternativa: confiar igual e contar com o undo.
4. **Conversa do Claude continua gravando decision/pitfall como `active`** (só registramos a origem). Alternativa:
   tudo da conversa vira `proposed` também no Claude (mais seguro, mais clique).
5. **Pausa** com 10 de 20 chamadas ruins.
6. **Modelo do Codex**: sem `-m` (padrão da CLI) com `reasoning_effort=low`. Alternativa: fixar um modelo pequeno.
7. **Limite padrão 40 para todos**, inclusive Ollama, até medir.
8. **Login próprio do Codex para o curador** (mais um login, nada compartilhado). Alternativa: usar o `~/.codex` do
   usuário com `AGENTS.md` e skills entrando no prompt.
9. **Claude atual sem folha de consentimento** (só o destino na linha). Alternativa: pedir a todos uma vez.
10. **“Testar com uma chamada”** gasta até 3 jobs (um por formato), com confirmação.
11. **Sugestão no painel** quando falta Claude, sem trocar sozinho; ASM com limitado não sobe nada sozinho.

## Riscos

- Flags do Codex vêm da documentação (não instalado aqui); `features list`, stdin e códigos de saída precisam ser
  pinados na versão real.
- O perfil `(deny default)` pode quebrar o Claude/Codex por um caminho de sistema esquecido; mitigação: teste manual
  do dono antes de trocar o perfil do Claude, e falha com motivo claro (“curador bloqueado pelo sandbox: <caminho>”).
- Conferir o dono do socket por libproc depende de API não documentada como estável para isso.
- Modelos locais pequenos erram schema e julgamento; a confiança limitada reduz o estrago e o que a memória aprende.
- A cota do plano é consumida em segundo plano; o limite diário é o freio do Codex.

## Notas da revisão (onde discordei ou ajustei)

- **I3**: procedimento usa `CuratorOps.schema`/`validate` (`ProcedureDetector.swift:163-164`), não um parser
  próprio. São três formatos (ops, items, chunks), não quatro.
- **I7**: `-c project_doc_max_bytes=0` não está documentado como desligar o `AGENTS.md` global; em vez dele,
  `CODEX_HOME` próprio com login próprio (sem copiar nem ligar o `auth.json`).
- **M8**: aceito; o limite sugerido para local virou 40 até medir.
- **M9**: `memoryReads` quer dizer “não muda registro” (decide se re-renderiza skills); `memory.curator` continua lá.
  O admin-only, que é o que importa, é herdado pelos parâmetros novos.
- **B5**: em vez de “ler o nome `:cloud`”, o estado oficial (`server.json`) manda; o nome fica como reforço.
- **I1**: além do `num_ctx`, `inputMax` passa a ser derivado do contexto (§2.5), porque o limite fixo de 12 000
  escalares não cabe em 4096 tokens.

## Tarefas (lista; o plano detalha)

Correções do estado atual (primeiro): 1. Veredito fail-closed (E1). 2. `config.json` tolerante (E7). 3. Origem e
confiança nos registros (E2). 4. Perfil Seatbelt dedicado (E5). 5. Login, stdin e `.exhausted` do Claude (E3, E4,
E6; **passo do dono**: fixtures de `auth status`). Multi-provedor: 6. Interface e registro de provedores.
7. Resultado do job, pausa e `inputMax` nos builders. 8. Confiança limitada. 9. Schema estrito. 10. Runner Ollama
(**passo do dono**: fixture e modelo de nuvem). 11. Runner Codex (**passo do dono**: instalar, `--help`,
`features list`, login, fixture). 12. Comando, status e consentimento. 13. Preferências e painel. 14. Docs dos specs
ASM/ciclo de vida (cedo). 15. Roteiro manual do dono.
