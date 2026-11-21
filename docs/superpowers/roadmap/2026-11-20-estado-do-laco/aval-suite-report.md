# Avaliação da suíte de testes: por que demora e como encurtar

_2026-11-21. Somente leitura: nada rastreado foi editado, nenhum arquivo criado fora deste. 10 suítes cronometradas, uma por vez, com `--skip-build`._

## Resumo (5 linhas)
1. **Hoje:** CI = ~8 min de build a frio (6:00 a 9:19) + Testes que, desde o `run-tests.sh` em shards seriais, **passam de 30 a 52 min** (1 cancelado aos 52 min, 1 rodando há 31+ min). O último verde (6:17) era o `swift test` puro, que mentia. Laço: check cumulativo ~3,9 min por tentativa + build próprio do agente (a frio, ~4–5 min, quando ele usa `.build/<nome>`).
2. **Maior fonte de demora no CI:** execução serial (`--no-parallel`) de 3705 testes em 3 shards, mais travas (2 de 3 shards ainda vivos aos 52 min, `adb` órfão). No laço: o check é limitado por **`AskTests` (serializada, 179 s sozinha)**, que fica no caminho crítico do cumulativo.
3. **Melhoria nº 1:** tirar `AskTests` do caminho crítico (relógio injetável nos limites de tempo do ask, ou subir para o portão do fim da onda). Ganho estimado **~2,5 min por check** (179 s → ~35 s, o próximo maior medido), ~45 min nas 37 tentativas pós-Motor. Confiança média.
4. **Nº 2:** CI com shards **paralelos dentro do shard, largura limitada** (ou mais shards) + timeout por shard. Leva os Testes de 30–52+ min para ~10–15 min (estimativa, confiança baixa).
5. **Bug achado:** `scripts/laco-check.sh` tem `LoopSectionTestsContextPanelLoopsTests` colado: `LoopSectionTests` e `ContextPanelLoopsTests` **não rodam** no check (falso negativo hoje).

## 1. Mapa

### Testes por alvo (contagem estática: `@Test` e linhas; `swift test list` no CI: 3711)
| Alvo | Arquivos | @Test | Linhas | Peso |
|---|---:|---:|---:|---|
| CollieDaemonKitTests | 226 | 2890 | 54,6k | daemon real (`withDaemon` 236×), git real (`makeRepo` 334×), sockets, processos |
| ColliePluginsTests | 29 | 376 | 6,6k | navegador/WebKit, snapshotter |
| CollieAppTests | 40 | 311 | 4,0k | UI/modelos; 1 XCTest |
| CollieCoreTests | 15 | 116 | 1,1k | puro |
| CollieClientTests | 11 | 83 | 1,4k | socket com daemon (DaemonClientTests: 14 sleeps) |
| CollieDeviceTests | 5 | 50 | 0,6k | adb |
| CollieProtocolTests | 7 | 47 | 0,5k | puro |
| CollieThemeTests | 7 | 43 | 0,4k | puro |
| CollieCanvasTests | 6 | 40 | 0,4k | puro |
| VizinhoKitTests | 3 | 35 | 0,5k | puro |
| CollieIntegrationTests | 6 | 34 | 0,9k | daemon/e2e |
| CollieTerminalTests | 3 | 26 | 0,4k | PTY, collie-ctty, sandbox |
| CollieNetworkTests | 5 | 25 | 0,3k | rede |

Todos os alvos vão para **um só bundle** (`colliePackageTests.xctest`): `swift test --filter X` compila e linka tudo, sempre.

### O que sobe coisa cara (grep por arquivo; contagem de arquivos)
| Sinal | Arquivos |
|---|---:|
| `Task.sleep`/`sleep` | 99 (299 ocorrências; 73 linhas no baseline do lint) |
| processo (`Process()`, `executableURL`…) | 59 |
| git real | 34 arq. de chamada direta; `makeRepo()` (6 processos git cada) usado 334× |
| daemon real (`withDaemon`) | 88 arq., 236 usos |
| socket | 98 |
| sandbox-exec/Seatbelt | 13 |
| navegador/WebKit | 25 |
| adb | 19 |
| `.serialized` | 128 arq. (serializa só dentro da suíte; não achei trava global) |

### Suítes cronometradas (local, `--skip-build`, uma por vez, máquina com load ~7 em 8 núcleos)
Os tempos por suíte do CI **não servem**: o run verde rodou tudo em paralelo num runner de 3 núcleos e quase toda suíte "levou" 250–330 s por fome de CPU (até `PaddockAppsTests`, que leva 0,5 s). O run com shards não imprime nada até o fim e foi cancelado. Então a tabela é a amostra local, escolhida pelas suspeitas (sleep, daemon, lista do laço). **Não consegui as 15 mais lentas medidas**; só 10 (limite do brief).

| # | Suíte | Testes | Tempo (testes) | Relógio do processo | Nota |
|---:|---|---:|---:|---:|---|
| 1 | AskTests | 53 | **178,8 s** | 180 s | `.serialized`, esperas reais de limite (22 s, 21 s, 20 s, 13 s, 12 s, 11 s…) |
| 2 | WorkChatCommandTests | 23 | 33,5 s | 35 s | 17 sleeps; 4–5 s por teste |
| 3 | ConversationCaptureTests | 27 | 15,8 s | 18 s | ~1,3 s por teste, serial |
| 4 | WorkLoopTests | 56 | 12,2 s | 20 s | |
| 5 | LoopParallelE2ETests | 9 | 7,4 s | 10 s | git + worktrees reais |
| 6 | BrowserAutomationTests | 23 | 6,6 s | 8 s | |
| 7 | LaneIntegrationTests | 8 | 5,9 s | 10 s | git real |
| 8 | CuratorQueueTests | 36 | 5,3 s | 7 s | |
| 9 | PluginStoreTests | 17 | 5,2 s | 9 s | `copyEnforcesCaps` 5,2 s sozinho |
| 10 | PaddockAppsTests | 1 (local) | 0,5 s | 6 s | no CI roda mais testes (outros pulam local) |

Custo fixo de cada `swift test --skip-build`: **4–8 s** (relógio − tempo dos testes).

Candidatas a lentas **não medidas** (pelo grep de sleep/daemon): CuratorQueue já foi; restam ApprovalTests (11 sleeps), DesignPanelTests (10), UserEnvironmentTests (9), PromptDeliveryTests (7), NetworkServiceTests, DaemonClientTests (14), BusyClaudeSubmitTests, os `Remote*Ask*`.

## 2. Onde vai o tempo

### CI (gh run view, 4 runs de 19–21/11)
| Etapa | 44521855224 | 44660112287 | 44790066091 | 44926559472 |
|---|---:|---:|---:|---:|
| Lint + arquitetura + scripts | 21 s | 13 s | 21 s | 32 s |
| Build (`swift build --build-tests`, frio) | 7:56 | 6:00 | 7:04 | 9:19 |
| Testes | 2:36 (falhou, Fatal) | 6:17 (verde falso, swift test puro) | **52:38 cancelado** | **31+ min, rodando** |

- **Build × teste:** antes dos shards, ~55% build. Agora ~15–20% build: **o teste serial domina**. Sem `actions/cache`: todo run compila a frio.
- **Por que os shards demoram:** `--no-parallel` em cada shard. Amostra local: ~0,45 s/teste sem AskTests, ~1,07 s/teste com ela. 3705 testes / 3 shards × 0,45–1,07 s ≈ **9–22 min por shard em CPU local**. O runner é mais lento, e há travas: no cancelado, 2 processos `swiftpm-testing` e um `adb` ainda vivos aos 52 min. Ou seja, algum teste espera sem limite quando roda serial (ou espera algo que só outro teste paralelo destravava). Confiança **baixa** na conta; **alta** no fato (52 min, 31+ min).
- **Fila:** pushes na main não cancelam (`cancel-in-progress` só em PR). O run 44928048461 está **pendente** atrás do que está rodando.

### Laço
- `laco-check.sh` = 1 `swift test` com 72 `--filter`, **em paralelo** (sem `--no-parallel`), no `.build` quente do cercado.
- Build incremental medido: **101 s** depois de alguns commits; no-op 0,6 s. Falha de compilação aparece em 6–24 s (aval-lacos).
- Execução: o paralelo do Swift Testing faz o relógio ≈ a maior suíte serializada. **AskTests (179 s) ≈ 3 min dos ~3,9 min** do check. Isso explica por que o check ficou estável em 3,5–4,5 min da Onda 6 à 9, mesmo com a lista crescendo. Confiança média: medi AskTests sozinha, não o conjunto (são 72 suítes, acima do limite de 10).
- O filtro é substring: `AskTests` também casa `RemoteAskTests`, `AskSubmitRetryTests` etc.; `CommandsTests` casa vários.
- **Build do agente:** a orientação de pasta compartilhada manda o agente compilar em `.build/<nome-do-terminal>` (`CollieOrientation.swift:166`). O nome muda por tentativa (`…-t1`, `…-t2`), então **cada tentativa compila a frio**: ~4–5 min, medido pelos mtimes de 827 `.o` em `onda-9-…-m9-2-…-t2`. Alguns agentes nem usam (pastas com 1–27 `.o`). Hoje `.build/` tem **98 GB**: ~95 dessas pastas, 1,7 GB cada, nunca limpas.
- aval-lacos: 45% do relógio dos agentes é build/teste próprio, e depois o laço roda o check de novo.

## 3. Desperdício
1. **Cumulativo por tarefa:** 72 suítes a cada tentativa, com a maioria sem relação com a tarefa. Pelo item 2, o custo real é AskTests no caminho crítico, mais o build.
2. **Esperas reais de relógio:** AskTests faz limites de verdade (`timeout: 1`, `heldCap`, "turn takes ~3.5 s"). 8 testes somam ~110 s. WorkChatCommandTests: 4–5 s por teste. O "já feito em parte" com continuations não chegou aqui.
3. **Fixtures caras por teste:** `makeRepo()` abre 6 processos git, 334 vezes (~0,2–0,4 s cada → 1–2 min de CPU serial, estimativa). `withDaemon` sobe um daemon real 236 vezes.
4. **Retry:** o `laco-check.sh` repete uma vez as suítes que falharam. Com AskTests instável sob carga, isso pode somar +3 min. Não medi a frequência.
5. **Build a frio por tentativa** no `.build/<nome>` (item 2) e 98 GB de lixo.
6. **Bug:** `LoopSectionTestsContextPanelLoopsTests` no array, e não houve correção de verdade em cd734e3 (o commit "fix suite list" só moveu o erro: antes era `MemoryServiceTestsLoopSectionTests`). Resultado: `LoopSectionTests` e `ContextPanelLoopsTests` saíram do check (`MemoryServiceTests` não existe como suíte; o nome sumiu sem efeito).
7. **Duplicação entre suítes:** não medi. Os nomes `*NitsTests` (Loop, LoopLane, Onda5, LoopResume) sugerem testes de achados de revisão espalhados, mas não comparei asserções.

## 4. Propostas

**P1. Tirar AskTests do caminho crítico.**
- Muda: os limites do ask (cap, timeout de turno, hook perdido) passam por um relógio/`Duration` injetável no `DaemonConfig`; nos testes, 50–200 ms em vez de 1–20 s. Alternativa sem código: tirar `AskTests` da lista por tarefa e rodar só no portão final.
- Ganho: 179 s → ~35 s no check (vira a WorkChatCommandTests); **~2,4 min por tentativa**, ~45 min em 37 tentativas.
- Risco: limite curto demais deixa o teste instável sob carga. Use margens relativas, não absolutas. A alternativa sem código adia a detecção para o fim da onda.
- Esforço: S (lista) / M (relógio).
- Medir: `checkFinished − checkStarted` no diário; `Test run … after` da AskTests.

**P2. CI: paralelo com largura limitada por shard + timeout por shard.**
- Muda: `scripts/ci/run-tests.sh`. Trocar `--no-parallel` por paralelo limitado. Verificar se o Swift Testing do 6.2 respeita `--num-workers` (o help diz "tests to execute in parallel"; para XCTest é certo, para Swift Testing não confirmei). Se não respeitar, subir `SHARDS` para 6–8 processos seriais. Mais `timeout 900` por shard, para uma trava virar falha com log em 15 min, não cancelamento aos 60.
- Ganho: de 30–52+ min para ~10–15 min (estimativa, confiança baixa). O ganho certo: travas passam a falhar em 15 min e mostram qual suíte.
- Risco: voltar à fome de CPU do run verde falso. Por isso a largura deve ser limitada (2–3), e a checagem por contagem final, que já existe, continua.
- Esforço: S.
- Medir: `shard i ok: N tests, Xs` já é impresso.

**P3. Achar e consertar a trava serial.**
- Muda: nada antes de medir. Rodar 1 shard localmente com `--no-parallel` e um timeout, para ver a última suíte iniciada sem fim (o `adb` órfão aponta para Device/Android).
- Ganho: é condição para P2 dar verde.
- Risco: nenhum.
- Esforço: S–M.
- Medir: log do shard.

**P4. Cache de `.build` no CI.**
- Muda: `.github/workflows/ci.yml`, `actions/cache` em `.build` com chave `hashFiles('Package.resolved')` + SHA e `restore-keys`.
- Ganho: build de 6–9 min → ~2–3 min (incremental medido local: 101 s; runner mais lento). **~4–6 min por run.**
- Risco: cache corrompido ou velho. SwiftPM recompila pelo que mudou; o build de release continua a frio. Tamanho: ~2 GB por cache.
- Esforço: S.
- Medir: duração da etapa Build.

**P5. Build do agente sem frio por tentativa.**
- Muda: `CollieOrientation.swift:166`. Usar um nome estável por cercado/laço (ex. `.build/laco`), em vez do nome do terminal, ou semear a pasta nova com clone APFS do `.build` principal (`cp -c -R`, instantâneo). Mais uma limpeza das pastas velhas (98 GB).
- Ganho: ~4–5 min por tentativa em que o agente obedece (medido 1 caso; confiança média-baixa).
- Risco: duas sessões vivas no mesmo `.build` disputam o lock. Por isso o nome é por laço, e no serial só um agente vive por vez.
- Esforço: S.
- Medir: mtimes dos `.o` da pasta, ou tempo do primeiro `swift build` do agente.

**P6. Check por área + fumaça; cumulativo só no portão final** (= P4 do aval-lacos).
- Muda: `scripts/laco-check.sh` passa a levar `need`-arquivo da tarefa + lista da área (fixa por tarefa no `case`, escrita pelo autor da onda) + fumaça fixa (~5 suítes rápidas: WorkLoopTests, AttemptMachineTests, WorkStoreTests, LoopJournalTests, CommandsTests). Cumulativo + suíte completa no fim da onda.
- Ganho: depois de P1, de ~1,5 min para ~0,5 min de execução por check. Sem P1, ~2,5 min.
- Risco de falso negativo: uma tarefa quebra suíte de outra área. O portão final pega, antes do merge. Não é seleção por diff: **a área é declarada no `case`, não inferida**. Assim não volta nenhum dos 5 caminhos do `affected-tests.sh` (executável por caminho, rename, pipefail, arquivo fora de Sources/Tests, escolha da base).
- Esforço: S.
- Medir: diário.

**P7. Corrigir a lista do `laco-check.sh` e torná-la verificável.**
- Muda: separar `LoopSectionTests ContextPanelLoopsTests`. Ancorar os filtros (`\.Nome/`) e falhar se um nome não casar nenhum teste em `swift test list --skip-build` (a mesma regra do `ci-skip.txt`).
- Ganho: 0 min. Fecha um falso negativo real.
- Esforço: S.

**P8. `makeRepo()` por cópia de molde.**
- Muda: o helper em `PaddockManagerTests.swift:13` cria um repo molde uma vez (`static let`) e copia com `cp -c -R` (clone APFS) por teste.
- Ganho: ~1–2 min de CPU serial no CI; pouco no laço (paralelo). Estimativa.
- Risco: datas/SHA iguais entre testes. Inofensivo, porque cada teste tem pasta própria.
- Esforço: S.

**P9. Tag `.slow` + alvo "rápido" × "completo".**
- Muda: `@Suite(.tags(.slow))` nas suítes > 10 s; `--skip` por tag para o uso local rápido. O CI e o portão final rodam tudo.
- Ganho: só para quem roda local amplo (raro, já que se usa `--filter`). Pequeno.
- Esforço: S, mas a lista apodrece.

**P10. Dividir CollieDaemonKitTests em alvos menores.**
- Muda: Package.swift, ~4 alvos de ~14k linhas.
- Ganho: pequeno. Tudo vai para um bundle só, e a maioria das tarefas muda `Sources/CollieDaemonKit`, o que recompila todos os alvos dependentes. Só ganha quando a mudança é só em teste.
- Esforço: L. Ver "não vale".

**P11. `swift build --build-tests` uma vez + `swift test --skip-build` por filtro.**
- No CI já é assim. No laço o check é um processo só; o ganho seria só em quem roda várias vezes (custo fixo de 4–8 s por chamada não some). Ganho: ~0.

## 5. Ranking (ganho × esforço × risco)
| # | Proposta | Ganho | Esforço | Risco |
|---:|---|---|---|---|
| 1 | P1 AskTests fora do caminho crítico | ~2,4 min/check (~45 min/37 tentativas) | S/M | baixo |
| 2 | P3 + P2 CI paralelo limitado + timeout por shard | CI de 30–52+ → ~10–15 min; trava vira falha em 15 min | S–M | médio (fome de CPU, controlada pela largura) |
| 3 | P4 cache de `.build` no CI | ~4–6 min/run | S | baixo |
| 4 | P5 build do agente com nome estável/clone | ~4–5 min/tentativa (quando usado) + 98 GB | S | baixo |
| 5 | P7 + P6 lista corrigida, área declarada + fumaça | fecha falso negativo; ~1–2,5 min/check | S | médio, coberto pelo portão final |

**Não vale:**
- **Seleção por arquivos alterados (volta do `affected-tests.sh`):** os 5 caminhos de falso negativo continuam lá, e o ganho já sai de P1/P6 sem inferência. Se um dia voltar, só como "roda mais", nunca "roda menos" que a área declarada.
- **Dividir alvos de teste (P10):** esforço L para ganho pequeno (bundle único, mudanças em Sources recompilam tudo).
- **`--parallel`/faixas no laço para ganhar tempo de teste:** cada faixa compila a frio, e as tarefas tocam os mesmos arquivos (aval-lacos).
- **Mais retry:** o retry esconde instabilidade (AskTests) e soma minutos. A regra do `ci-skip.txt` ("instável se conserta, não se lista") vale para o laço também.
- **Trocar daemon/git reais por fakes em massa:** a amostra mostra que suítes com daemon/git real levam 5–12 s. O custo está em esperas de relógio, não nas fixtures. Fake só onde a regra real não está em jogo e a suíte passar de ~10 s.

## Fontes e confiança
| Número | Fonte | Confiança |
|---|---|---|
| Etapas do CI (build 6–9 min, testes 52 min/31+ min) | `gh run view` dos runs 44521855224, 44660112287, 44790066091, 44926559472 | alta |
| Tempos por suíte do CI (250–330 s) | log do 44660112287 | inútil (fome de CPU) |
| 10 suítes locais | `swift test --skip-build --disable-sandbox --skip MemoryEventEmissionTests --filter "\.Nome/"`, uma por vez, load ~7 | média (máquina compartilhada) |
| Build incremental 101 s, no-op 0,6 s | `time swift build --build-tests` local | média |
| AskTests ≈ caminho crítico do check | dedução: medida isolada + check estável em ~3,9 min (aval-lacos) | média; medir rodando o check sem AskTests |
| Shards 9–22 min | extrapolação de 253 testes amostrados | baixa (amostra enviesada para os lentos) |
| Build a frio do agente ~4–5 min | mtimes dos `.o` de uma pasta `.build/<nome>` | média-baixa (1 caso) |
| Ganho do cache no CI | incremental local × frio no runner | baixa-média |
| `makeRepo` 1–2 min | 334 usos × 6 processos git, custo por processo estimado | baixa |

**Não medi:** o check cumulativo inteiro (72 suítes, acima do limite); o tempo serial real de um shard; qual teste trava no shard; a frequência do retry do laço; a duplicação de testes entre suítes; se o Swift Testing 6.2 respeita `--num-workers`.
