# Avaliação dos laços: tokens, desempenho e o que o daemon pode fazer a mais

Janela: 2026-11-19 00:00 a 2026-11-21 ~17:00 (UTC). Somente leitura. Índice relativo: entrada 1, cache criado 1,25, saída 5, cache lido 0,1. "M" = milhão de unidades do índice.

## Em 5 linhas
1. **Número que mais importa:** o Pastor gastou **40% do cercado** (46,9 M de 117,7 M), e **86% disso é cache lido**: cada chamada relê um contexto que chegou a **690 mil tokens** (média ~370 mil por chamada).
2. **Maior desperdício:** contexto grande relido. Vale para o Pastor e também para os agentes, porque cada agente de tentativa já nasce com **~69 mil tokens** de contexto. Desses, ~37 mil são anexos do ambiente do usuário (lista de skills, ferramentas MCP adiadas, hooks de início de sessão), e a tarefa não usa nenhum deles.
3. **A Onda 5 funcionou para o Pastor, não para os agentes:** o custo do Pastor por tarefa caiu de 0,47 M para 0,13 M (−73%) nas Ondas 7 a 9. O custo por tentativa dos agentes não mudou (0,47 M → 0,44 M).
4. **Toda falha depois da Onda 5 foi erro de compilação** (6 de 6, sem contar o teste visual). Em 5 delas o agente encerrou o turno com build ou teste ainda rodando em segundo plano.
5. **Melhoria nº 1:** lançar os agentes de laço com um ambiente enxuto: só o MCP do Collie, sem as skills e os plugins do usuário, sem os hooks de início de sessão do usuário. Ganho estimado de ~95 mil por tentativa (~20% do gasto dos agentes), esforço S.

## Como medi (e confiança)
- **Tokens:** script próprio sobre os transcripts do Claude Code deste cercado. Ele soma `usage` (entrada, saída, cache criado, cache lido) por mensagem do assistente, uma vez por id. Leu **só números**, nunca o texto. Alguns metadados estruturais também entraram: o tipo de cada anexo e o seu tamanho em bytes, o nome de cada ferramenta usada, a flag `run_in_background` e os horários. Confiança **alta** nas somas.
- **Papéis:** o Pastor é a sessão longa do terminal principal. Um agente de tentativa é uma sessão cujo prompt inicial é o do laço, casada com o `agentSummoned` do diário (início entre −5 s e +180 s). Um revisor é uma sessão iniciada por um brief `rev-*`. O casamento deu 31 tentativas com diário completo, com sessão achada em todas. Confiança **alta** para as Ondas 6 a 9. Para as Ondas 1 a 3c, os resumos são "reconstruídos", com diário de no máximo 20 eventos. Nelas atribuí as sessões à onda pela janela aberto→fechado. Confiança **média**: um revisor que começou dentro da janela conta para a onda.
- **Tempos e falhas:** `collie work history --id` (diário, notas, `loopSummary`) e as notas de falha. Confiança **alta** a partir da Onda 6 e **média** antes dela, porque as causas antes da Onda 6 vêm do texto das notas.
- **O que não consegui medir:**
  - O peso real de cada modelo no limite semanal: o índice ignora o preço, e Opus provavelmente pesa mais.
  - Se `--parallel` foi usado de fato: não há sessões em worktrees `lane-*`.
  - O tempo de compilação a frio nas faixas.
  - Quanto cada anexo pesa em tokens exatos: estimei pelos bytes.
- **`collie work usage` não serviu:** ele responde "Nenhum trabalho neste cercado" para trabalhos fechados, e o resumo imutável (`work-archive`) não traz os tokens da M5.4. Ver a proposta P6.

## 1. Gasto

### Por onda (índice, M)

| Onda | Feitas | Na 1ª | Sessões de tentativa | Laço | Pastor | Agentes | Revisor | Total | Por tarefa |
|---|---|---|---|---|---|---|---|---|---|
| Layout Trilho | 5 | 5/7 | 8 | 14 min | 3,6 | 1,7 | – | 5,3 | 1,06 |
| 1 | 4 | 4/4 | 4 | 38 min | 2,5 | 1,5 | 0,7 | 4,7 | 1,18 |
| 1b | 3 | 2/4 | 3 | 1h35 | 3,0 | 1,1 | – | 4,1 | 1,37 |
| 2 | 7 | 4/8 | 10 | 1h37 | 6,7 | 4,0 | 0,5 | 11,2 | 1,60 |
| 2b | 2 | 1/2 | 3 | 23 min | 2,6 | 1,2 | 0,4 | 4,2 | 2,10 |
| 3 | 9 | 5/9 | 14 | 2h37 | 1,5 | 6,4 | 1,3 | 9,2 | 1,02 |
| 3b | 6 | 5/6 | 13 | 1h54 | 3,7 | 5,8 | 1,7 | 11,2 | 1,87 |
| 3c | 4 | 4/4 | 4 | 1h29 | 1,0 | 2,9 | 1,0 | 4,9 | 1,23 |
| Trilho 2 | 5 | 3/5 | 6 | 48 min | 1,0 | 2,1 | – | 3,1 | 0,62 |
| Motor (3d + Onda 5) | 10 | 9/10 | 11 | 2h29 | 1,5 | 6,7 | 1,3 | 9,5 | 0,95 |
| 6 (daemon antigo, ver §2) | 5 | 3/5 | 8 | 1h00 | 1,2 | 3,5 | 0,8 | 5,5 | 1,10 |
| 7 | 3 | 3/3 | 3 | 32 min | 0,3 | 1,4 | – | 1,7 | 0,57 |
| 8 | 3 | 2/3 | 4 | 37 min | 0,3 | 1,7 | 0,9 | 2,9 | 0,97 |
| 9 | 2 | 0/2 | 4 | 23 min | 0,4 | 1,7 | – | 2,1 | 1,05 |
| Fora de laço (19/11, entre ondas) | – | – | 27 | – | 17,2 | 7,8 | 1,0 | 26 (+8,8 outros) | – |

- **Totais da janela:** este cercado 117,7 M; os outros projetos/cercados 37,7 M. Este cercado foi **76%** do uso da conta.
- **Por papel no cercado:**

  | Papel | Índice | Parte |
  |---|---|---|
  | Pastor | 46,9 M | 40% |
  | Agentes de tentativa | ~50 M | 43% |
  | Revisores | ~9,6 M | 8% |
  | Outros (sessões avulsas, subagentes) | ~11 M | 9% |

- **Composição:**

  | Papel | Cache lido | Cache criado | Saída | Entrada |
  |---|---|---|---|---|
  | Pastor | 86% | 7% | 7% | ~0 |
  | Agentes e revisores | 53% | 26% | 21% | ~0 |

- **Modelos (índice):**

  | Quem | Modelo | Índice |
  |---|---|---|
  | Pastor | Sonnet 5.5 | 46,9 M (com contexto de 1M) |
  | Agentes, revisores e avulsos | Opus 5.5 | 33,0 M |
  | Agentes, revisores e avulsos | Fable 5.2 | 32,6 M (Ondas 1 a 3, sobretudo) |
  | Agentes, revisores e avulsos | Sonnet 5.5 | 4,7 M |
  | Agentes, revisores e avulsos | Haiku 5.5 | 0,1 M |

  Desde a Onda 3b, todo agente roda Opus. A M5.6 criou o `loopModel`, mas ele está sem valor, então os agentes herdam o modelo.

### Por tentativa (Ondas 3 a 9, 31 com diário completo)

| | Passou (24) | Falhou (7) |
|---|---|---|
| Tokens (média) | 0,48 M | 0,41 M |
| Chamadas (média) | ~24 | ~22 |
| Contexto na 1ª chamada | 69 mil (todas: 31,6 mil lidos do cache + ~37 mil **criados** por sessão) | igual |
| Contexto máximo | 94 a 220 mil | 71 a 151 mil |

- **Custo fixo de nascer:** 1,25 × 37 mil + 0,1 × 31,6 mil ≈ **49 mil** só na 1ª chamada. Cada chamada seguinte relê esses 69 mil (≈ 6,9 mil cada). Em ~23 chamadas, o prefixo custa **~0,2 M**, cerca de 40% de uma tentativa.
- **De onde vêm os ~37 mil**, por bytes dos anexos de uma sessão típica:

  | Anexo | Tamanho |
  |---|---|
  | Lista de skills | ~67 KB |
  | Lista de ferramentas MCP adiadas | ~60 KB |
  | Hooks de início de sessão do usuário | ~57 KB, em 7 blocos |
  | Lista de agentes | ~16 KB |
  | Instruções de servidores MCP | ~13 KB |
  | Instruções do projeto/usuário | ~6 KB |
  | Memória e armadilhas do Collie | ~6 KB |
  | Prompt da tentativa | ~3 KB |

  Confiança **média** na divisão, porque converti bytes em tokens. O total de 37 mil está medido, com confiança **alta**.

### Onde está o desperdício (janela inteira, estimado)

| Fonte | Índice | Conta |
|---|---|---|
| Pastor relendo contexto grande | ~24 M evitáveis | 1086 chamadas × (370 mil − 150 mil) × 0,1 |
| Prefixo inútil dos agentes e revisores | ~13 M | ~140 sessões × ~95 mil (ver P1) |
| Tentativas queimadas | ~16 M | ~41 tentativas extras × ~0,4 M (ver §4) |
| Revisões longas | não é desperdício relevante | 0,4 a 1,7 M cada, 8% do total |
| Pastor acordando por aviso | caiu de ~15 M para valores pequenos nas Ondas 7 a 9 (ver §2) | – |

## 2. Antes × depois da Onda 5

- **Onda 6 rodou no daemon antigo.** Ela recebeu um aviso por tarefa, e o Stop hook do Pastor pediu "registre decisões" depois de cada tarefa, com o laço ainda rodando. Isso é o comportamento anterior à M5.1 e à M5.2. A partir da Onda 7 só chegam "Laço iniciado" e "Laço terminou", e o Stop hook só aparece depois do fim do laço. Confiança **média-alta**. Por isso o "depois" abaixo é Ondas 7 a 9.

| Métrica do Pastor | Ondas 1 a Motor (50 tarefas, 13,5 h de laço) | Onda 6 | Ondas 7 a 9 (8 tarefas, 1,5 h) |
|---|---|---|---|
| Índice por tarefa feita | 0,47 M | 0,24 M | **0,13 M (−73%)** |
| Acordadas automáticas por hora de laço (aviso, notificação, Stop hook) | 14,4 | 10 | **7,2 (−50%)** |
| Chamadas por hora de laço disparadas por eventos | 27 | 23 | 31 |
| Índice por chamada automática | 43 mil | 48 mil | **19 mil (−56%)** |
| Contexto médio por chamada | ~400 mil | ~430 mil | **~130 mil** |

- **Leitura:** metade do ganho veio de o Pastor acordar menos (M5.1 e M5.2: −50% de acordadas). A outra metade veio do contexto menor: a sessão do Pastor foi compactada às 09:56 de 21/11 e caiu de ~460 mil para ~90 mil antes da Onda 7. O conselho da M5.5 (ou um texto compatível) apareceu duas vezes antes disso, às 05:06 e às 07:35. A compactação veio ~2,5 h depois.
  - O número de chamadas por hora não caiu. Cada acordada agora vira mais chamadas (~4,4 contra ~1,9), porque o Pastor consulta o status ao acordar.
  - As notificações de `work wait` em segundo plano (orientação da M6.5: `--timeout 540`) ainda acordam o Pastor de 1 a 2 vezes por laço.
- **Por que a M5.5 não basta:** o limite dela é o **tamanho do arquivo** do transcript (20 MB). Esse arquivo só cresce, inclusive depois de uma compactação, e não mede o contexto real. O contexto real está na última `usage` (entrada + cache criado + cache lido), que o daemon já lê na `SessionUsage`.
- **Agentes:** 0,47 M por tentativa antes e 0,44 M depois. A Onda 5 não mexeu neles, nem no modelo: o `loopModel` continua sem valor.
- **M5.3 (limite de uso):** nenhum evento de limite na janela depois da instalação. Não deu para validar.
- **M5.4 (tokens por tentativa):** os números não chegam ao resumo imutável, e `work usage` não mostra trabalhos fechados. O dono não consegue ver o gasto depois que o laço fecha.

## 3. Desempenho

| Fase (Ondas 3 a 9, diário completo) | Passou: média / mediana | Falhou |
|---|---|---|
| Agente (summon → fim de turno) | 8,8 / 7,7 min | 3,1 min |
| Check (`laco-check.sh`, cumulativo) | 3,9 / 3,9 min | 0,2 min (falha de compilação incremental: 6 a 24 s) |
| Portão | ~2 s | – |

- **Testes repetidos:** em 70 sessões de agente (desde 20/11 14h), **4,9 h de 10,8 h de relógio (45%)** foram build ou teste em primeiro plano feitos pelo próprio agente. Depois disso, o laço roda o check cumulativo de novo, hoje com 72 suítes. Na prática, cada tarefa compila e testa duas vezes.
- **Compilação a frio:** não pesa no modo serial. O `.build` do cercado fica quente entre tentativas, e as falhas de compilação aparecem em 6 a 24 s. Ela só pesaria em faixas (`--parallel`), onde a memória do projeto registra mais de 10 min a frio por worktree nova. Não medi aqui.
- **Check cumulativo:** a lista cresce a cada onda (72 suítes hoje), mas o tempo ficou estável em ~3,5 a 4,5 min da Onda 6 à 9. Rodar só a suíte nova e a área tocada daria ~1 a 1,5 min (estimativa, confiança **baixa**): ~2,5 min por tentativa, ~45 min nas 37 tentativas pós-Motor. O cumulativo fica para o portão do fim da onda.
- **`--parallel`:** ganho incerto. As tarefas de uma onda tocam os mesmos arquivos (`WorkLoop.swift`, `WorkStatusText`). A integração serial refaz o portão, e cada faixa compila a frio. Para ondas de 2 a 5 tarefas, não compensa sem cache de build compartilhado.

## 4. Falhas

### Taxa de 1ª tentativa
Layout 5/7 · 1: 4/4 · 1b: 2/4 · 2: 4/8 · 2b: 1/2 · 3: 5/9 · 3b: 5/6 · 3c: 4/4 · Trilho 2: 3/5 · Motor: 9/10 · 6: 3/5 · 7: 3/3 · 8: 2/3 · 9: 0/2.
No total foram **50 de 72 tarefas (69%)** na 1ª tentativa e cerca de 41 tentativas extras.

### Causas das tentativas extras (pelas notas)

| Causa | Classe | Ondas | Quantas | O daemon poderia detectar sozinho? |
|---|---|---|---|---|
| Turno encerrado sem commit ("no new commit") | ambiente/agente | Layout, 1b, 2, 3, 3b, Trilho 2 | ~13 | Sim. Já existe a cutucada (M2.1). Nenhum caso depois do Motor |
| Prompt não submetido ("did not submit") | ambiente | 1b, 2, 3b | 4 | Corrigido pela M2.0. Nenhum depois da 3b |
| **Erro de compilação** (isolamento de ator, `await` dentro de `#expect`, macro) | bug real, barato | 2, 3b, Trilho 2, 6 (3), 8, 9 (2) | 9 | **Sim:** um `swift build --build-tests` de ~15 s com a mesma sessão viva. Em 5 dos 6 casos pós-Motor, a sessão terminou com build ou teste em **segundo plano** + `Monitor`. Uma regra do README ("nunca `await` em `#expect`") foi violada de novo na M9.2 |
| Teste falhou (comportamento) | spec ruim (M2.2: 3 testes de nome desconhecido, depois dividida), flaky de relógio (M2b), bug real (M3.1, M3b, M5.6) | 2, 2b, 3, 3b, Motor | ~10 | Em parte. Lint de spec para nomes citados que não existem. Flaky: repetir só a suíte que falhou uma vez |
| Portão falhou | indefinido (sem nota útil) | Layout | 3 | – |
| Terminal saiu / orçamento de tempo | ambiente | 3b | 1–2 | Já registrado como motivo tipado |
| Teste visual (dorme 90 s de propósito) | por desenho | Teste | 1 | – |

- **Custo de uma tentativa queimada depois da Onda 5:** ~0,41 M, ~3,5 min de agente e um agente novo que reaquece 69 mil e relê os arquivos.

## 5. Propostas para o daemon

### P1. Lançamento enxuto do agente de laço
- **O que faz:** a tentativa (e, opcionalmente, o revisor) sobe só com o necessário.
  - `--strict-mcp-config` com o MCP do Collie.
  - Sem os plugins, skills e hooks de início de sessão do usuário, por exemplo com `--setting-sources project,local` e as próprias configurações do Collie via `--settings`. Os hooks do Collie (Stop, para o fim de turno) continuam.
  - Conferir os nomes das flags na versão instalada do Claude Code; confiança **média** de que todas existem com esse nome.
- **Onde entra:** `AgentLaunch.swift:140-146`, que hoje é aditivo de propósito ("the user's own MCP servers stay"). O laço passaria um modo `lean` no summon (`WorkLoop` → host → launch).
- **Ganho:** contexto inicial de ~69 mil para ~40 mil, ou seja, −27 a 29 mil.
  - Por tentativa: 1,25 × 28 mil + 0,1 × 28 mil × 22 chamadas ≈ **95 mil (~20%)**.
  - Na janela: ~125 sessões de agente + 14 de revisor ≈ **~13 M (11% do cercado)**.
  - A 1ª resposta também fica mais rápida.
- **Risco:** o agente perde uma ferramenta de que a tarefa precisava. É baixo, porque o laço de código usa Bash, Read, Edit e o MCP do Collie. Deixar uma opção para voltar ao modo completo por tarefa ou por laço.
- **Esforço:** S.
- **Como medir:** `first` (entrada + cache criado + cache lido da 1ª chamada) por tentativa, que hoje é de 69 mil. A meta é ≤ 42 mil.

### P2. Pré-check na mesma sessão antes de julgar
- **O que faz:** no `turnEnded`, antes de dispensar o agente, o laço roda um pré-check rápido opcional por trabalho (`--precheck`, por exemplo `swift build --build-tests`). Se falhar, devolve o rabo da saída (`evidenceTail`, já existe) **ao mesmo agente**, no máximo uma vez, como a cutucada da M2.1. Só depois roda o check e conta a tentativa.
- **Onde entra:** `AttemptMachine.swift`, com um evento novo `precheckFailed` e o efeito `nudge(text)`. A decisão continua pura, com linhas novas na tabela. Em `WorkLoop`, ao lado do `nudgePrompt`.
- **Ganho:**
  - Pegaria 6 de 6 falhas pós-Motor e 9 de ~41 no total.
  - Cada uma economiza ~0,3 M (0,41 M de uma tentativa nova menos ~0,1 M de correção com o contexto quente) e ~3 a 4 min.
  - Na janela: ~2,7 M e ~35 min. A 1ª tentativa das Ondas 6 a 9 teria passado de 8/13 para ~13/13.
- **Risco:** o agente "conserta" em loop. Mitigação: uma vez só, com tempo limitado pelo orçamento da fase.
- **Esforço:** M.
- **Como medir:** a taxa de 1ª tentativa e o novo evento `precheckFailed` no diário.

### P3. Conselho de contexto por tokens + passagem de onda
- **O que faz:**
  - A M5.5 passa a medir o **contexto real**: a última `usage` do transcript (entrada + cache criado + cache lido), que a `SessionUsage` já lê. O limite seria, por exemplo, 200 mil tokens, no lugar dos 20 MB de arquivo.
  - No fim de cada laço, o daemon escreve um resumo curto de passagem: o `loopSummary`, as tarefas, os commits e a próxima onda prevista no roadmap. O conselho aponta esse resumo ("sessão nova: leia `collie work history --id …`").
- **Onde entra:** `Memory/ContextAdvice.swift` (trocar `size` por tokens da última mensagem) e `WorkStatusText.loopEnded`.
- **Ganho:**
  - O Pastor fez 1086 chamadas na janela, com média de 370 mil de contexto. Com ~150 mil, seriam −22 M a −24 M (**~20% do cercado**).
  - Já observado: depois da compactação, o Pastor por tarefa caiu de 0,47 M para 0,13 M.
- **Risco:** depende de o Pastor obedecer, porque o daemon não pode encerrar a sessão. Há perda de contexto útil, mitigada pelo resumo e pela memória.
- **Esforço:** S (limite) + S (resumo).
- **Como medir:** contexto médio por chamada do Pastor por hora, que hoje passa de 400 mil antes de compactar.

### P4. Check por área durante a onda, cumulativo no portão final
- **O que faz:**
  - O check de cada tarefa roda a suíte nova e as suítes do módulo tocado (`git diff --name-only` → alvo). O cumulativo de 72 suítes vira o portão do **fim do laço**, uma vez por onda e não uma vez por tarefa.
  - O prompt diz ao agente qual comando o laço vai rodar, para ele não rodar o cumulativo antes.
- **Onde entra:** `scripts/laco-check.sh` (projeto) e, no daemon, um `--final-gate` em `WorkLoopCommands`/`WorkLoop` que roda uma vez antes do `loopEnded`.
- **Ganho:** ~2,5 min por tentativa (~45 min nas 37 tentativas das Ondas Motor a 9). Não muda os tokens.
- **Risco:** uma regressão em outra área só aparece no fim da onda, e aí não há tarefa para culpar. Mitigação: o portão final que falha reabre a última tarefa.
- **Esforço:** M.
- **Como medir:** `checkFinished − checkStarted` no diário.

### P5. Regra de turno no prompt da tentativa
- **O que faz:** duas linhas fixas no `WorkLoop.prompt`:
  - "Rode build e testes em primeiro plano; não encerre o turno com comando em segundo plano nem `Monitor` pendente."
  - "`swift build` não compila os testes: use `--build-tests` ou `swift test --filter`."
  - Opcional: proibir a ferramenta `Monitor` no lançamento enxuto (P1).
- **Onde entra:** `WorkLoop.swift:855-868`.
- **Ganho:** cobre a causa das 5 falhas com segundo plano. É complementar à P2, que é a rede de segurança.
- **Risco:** quase nenhum.
- **Esforço:** S.
- **Como medir:** sessões de tentativa cuja última ferramenta é `run_in_background`/`Monitor`. Hoje são 10 de 19 nas Ondas 6 a 9, sem contar o teste visual.

### P6. Tokens no resumo imutável e `work usage` para trabalhos fechados
- **O que faz:** a contagem por tentativa da M5.4 (`attemptTokens`) entra no `WorkArchive` (tarefa → tentativas → `TokenCount`, modelo, minutos de agente e de check). `work usage` passa a ler os arquivos fechados.
- **Onde entra:** `Work/WorkSummary.swift`, `Work/WorkArchiveFiles.swift` e o comando `work.usage`.
- **Ganho:** nenhum token direto. Torna esta avaliação um comando: o dono vê qual onda custou quanto.
- **Esforço:** S.
- **Como medir:** `collie work usage` devolve números para as Ondas 7 a 9.

### P7. Modelo por papel (`loopModel` com padrão)
- **O que faz:** sugere um padrão para tarefas mecânicas (Sonnet). Mantém Opus por tarefa (`--model`) e para revisores.
- **Onde entra:** `WorkLoopCommands.loopModel` e `CollieSettings`.
- **Ganho:** **não medível pelo índice**, que ignora o preço. O Trilho 2 rodou em Sonnet com o mesmo volume de tokens (0,2 a 0,5 M) e passou. Se o limite semanal pesa Opus mais, o ganho é proporcional a 33 M em Opus.
- **Risco:** mais falhas em tarefas de concorrência Swift.
- **Esforço:** S (só configuração).
- **Como medir:** a taxa de 1ª tentativa por modelo.

### P8. Lint de spec antes da 1ª tentativa
- **O que faz:** antes de gastar a tentativa 1, confere que:
  - os caminhos citados na spec e no `need` do check existem ou são para criar;
  - os nomes de suítes do `--filter` existem ou são criados pela própria tarefa;
  - o comando do check é executável.
- **Onde entra:** `WorkLoopCommands` (`work run`), como aviso e não como recusa.
- **Ganho:** os casos de spec ruim da janela (M2.2, parte da M3.1) foram 3 a 5 tentativas, ~1,5 M.
- **Risco:** falsos positivos em arquivos que a tarefa cria.
- **Esforço:** M.
- **Como medir:** as falhas classificadas como spec.

## 6. Ranking (ganho por esforço)

| # | Proposta | Ganho | Esforço |
|---|---|---|---|
| 1 | **P1 lançamento enxuto** | ~11% do cercado, determinístico | S |
| 2 | **P3 conselho por tokens + passagem** | até ~20% do cercado; depende do Pastor | S |
| 3 | **P5 regra de turno no prompt** | cobre a causa nº 1 das falhas atuais | S |
| 4 | **P2 pré-check na mesma sessão** | 1ª tentativa ~100% nas falhas de compilação, ~0,3 M e ~4 min por caso | M |
| 5 | **P6 tokens no arquivo / `work usage`** | visibilidade, base para medir 1 a 4 | S |

Depois desses: P4 (minutos, não tokens), P7 (depende de como o limite pesa o modelo) e P8.

### O que não vale fazer agora
- **Orçamento de tokens por tentativa com parada antecipada:** nenhuma tentativa fugiu do padrão (máximo 1,1 M, contexto máximo 220 mil). Pararia tarefas boas.
- **Cache de build entre tentativas:** no modo serial o `.build` já é compartilhado (as falhas compilam em 6 a 24 s). Só faria sentido para faixas.
- **Investir em `--parallel` para economizar:** compilação a frio por faixa, arquivos em comum e integração serial. Não há ganho de tokens, porque a mesma quantidade de agentes roda.
- **Poda da memória injetada pelo Collie:** ~6 KB (~1,5 mil tokens), menos de 5% do prefixo. A P1 resolve o que importa.
- **Revisões como laço de leitura:** são 8% do total e cada uma é única. Ganho pequeno.
- **Mais redução de avisos do laço:** depois da M5.1, são 2 avisos por laço. O que resta é o `work wait` em segundo plano do Pastor e o contexto dele (P3).
- **"Tentativa lê só os arquivos citados":** não medi a leitura, porque exigiria olhar conteúdo. A P1 corta o maior custo fixo sem esse risco.
