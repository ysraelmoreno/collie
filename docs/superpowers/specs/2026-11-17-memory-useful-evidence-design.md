# Memória, item 2: uso útil com evidência — design

Data: 2026-11-17. Status: rascunho para aprovação. Sem código de produto.
Base: HEAD de feat/doc-memory (`00aeef8`), worktree `feat/mem-useful`.

## Intenção e porquê

Hoje uma memória injetada por relevância ao prompt ganha um **uso útil** quando o próximo prompt do mesmo terminal não é
uma correção. A medição (spec `2026-11-17-memory-measurement-baseline.md`) mostra o efeito: 182 de 230 memórias elegíveis
(79%) chegaram a `earned` com zero marcações `useful`, e só houve 6 correções em 945 prompts em 7 dias. "Ninguém reclamou"
é quase sempre verdade, então a precisão medida tende a ~100% e o tier `earned` deixa de separar memória boa de memória
apenas injetada. O item 1 (piso de relevância) também não aparece no número enquanto isso valer.

O dono quer que o uso útil exija evidência de que o agente **de fato usou** a memória, sem apagar nada, sem quebrar a
linha de base e sem dar ao agente (não confiável) um jeito novo de promover a própria memória.

## Estado atual (conferido no código)

- **Pendência de uso.** `hits(for:)` (`MemoryService.swift:705-712`) grava em `lifecycle.json` (`setPending`) os ids
  `eligible` da **última** injeção em `prompt`; `pull` (memory.task do Cursor) não mexe na pendência.
- **Resolução.** `resolvePending(for:correction:)` (`MemoryService.swift:740-749`), chamado no `memory.hookRelevant`
  (`MemoryCommands.swift:257-258`) antes da busca do prompt novo: correção (`CorrectionDetector.isCorrection(prompt,
  lastTurn:)`) → evento `used` com `reason = correction`; senão `lifecycle.addUse(ids, UseKey{day, session})` e evento
  `used` com os ids aceitos. `endSession` descarta a pendência (sem próximo prompt, sem uso).
- **Estado.** `LifecycleEntry` (`LifecycleStore.swift:10-28`): `usefulUses: Set<UseKey>` (um por dia UTC × sessão),
  demais campos opcionais/aditivos (`store`, `gatedAt`, `textHash`, `promotionUndone`, `flagPenalty`). Arquivo inteiro
  reescrito por mudança; JSON indecodificável vai para `.corrupt`.
- **Regras** (`LifecycleRules.swift`): `earned` = ≥ 2 usos, ≥ 2 dias, ≥ 2 sessões, sem contestação; o tier gravado é
  pegajoso (`tier(for:)` só reavalia `provisional`). `promotionCandidate` = ≥ 8 usos em ≥ 4 dias cobrindo ≥ 14 dias +
  portão do curador. `unusedPlan` (prazo por tipo, item 6) conta o relógio de `max(tierSince, último usefulUse)`. O índice
  do início de sessão (item 5, `MemoryService.swift:1027-1032`) e o bloco longTerm (`:987`) ordenam por `usefulUses.count`.
- **Marcação.** `applyFlag(... .useful)` (`MemoryService.swift:768-771`) chama `addUse` na hora (só id injetado na
  sessão do chamador, `flagTarget`, ≤ 20 por sessão). Medido: 0 em 7 dias.
- **Fim de turno.** O hook `claude-stop` (CLI, no contexto do agente) extrai a última mensagem do assistente
  (`HookPayload.claudeStopMessage`: `last_assistant_message`, ou os últimos 2 MiB do transcript **lidos pelo hook, não
  pelo daemon**) e manda `turn.completed {message}`. O Codex manda a mesma coisa pelo `notify`
  (`codexNotifyMessage`). O roteador guarda só os últimos 500 caracteres em `lastTurn[terminal]` (memória do ator, usado
  pelo detector de correção) (`CommandRouter.swift:493`).
- **Ferramentas.** O `PostToolUse` do Claude manda o payload inteiro (≤ 64 KiB, `tool_name`, `tool_input`) para
  `work.hook`; só o `WorkHookParser` olha (TodoWrite, Task, Agent, Bash em background). Nada de memória.
- **Leituras.** `memory.get` e `memory.search` emitem `searched` com os ids e o terminal (`MemoryCommands.swift:110,184`).
  Medido em 7 dias: 13 buscas, 97 resultados, contra 605 prompts com memória.
- **Por agente** (`AgentLaunch.swift:118-165`):
  - **Claude:** SessionStart, UserPromptSubmit, PostToolUse, Stop. Único que gera pendência de uso.
  - **Cursor:** só `sessionStart` (cursor-agent 2026.10.22); sem hook de prompt, de ferramenta ou de fim de turno. Recebe
    memória no início e por `memory_task` (pull). Tem `memory_get`/`memory_flag` via MCP.
  - **Codex:** só `notify` no fim do turno (com a mensagem). Nenhuma injeção, logo nada a usar.
- **Mapas.** `MemoryRecord.path` só em `.map`; o projeto real tem **0 mapas** ativos (126 armadilhas, 104 decisões).
  Armadilhas (`PitfallClasses`) não têm ligação com arquivo: classe = título/assunto/corpo/exemplos.
- **Proveniência.** Só registro verificado (`provenance.isVerified`) é injetado por inteiro e recebe pendência
  (`MemoryService.swift:359,405,527,677`); regra anti-lavagem do curador (`MemoryLearning.swift:333`, `PitfallClasses.swift:211`):
  texto que o daemon não escreveu nunca vira alvo.
- **Linha de comando.** O daemon instalado (0.1.0, de 15/11) é anterior à Leva 1: não emite `used` nem `eligible`. A
  precisão da Leva 1 ainda não foi medida em produção.

## Metas

- Um segundo contador, **uso com evidência**, ao lado do implícito, sem trocar um pelo outro.
- Evidência barata, local, sem ler conversa no daemon e sem guardar texto: só id, dia, sessão e o tipo de sinal.
- A precisão passa a discriminar: duas taxas lado a lado, cada uma com definição versionada.
- Mudança de regra (earned/longTerm) só depois de dados de sombra e por decisão do dono; reversível por constante.

## Não metas

- Rebaixar retroativamente as 183 `earned` de hoje.
- Hooks novos no Cursor ou no Codex (o Cursor não tem; o Codex não recebe injeção).
- Pedir ao agente que cite memórias no Stop (enviesaria a medida; ver Minhas chamadas).
- Juiz por modelo para cada uso (custo do curador; fica só no portão de longTerm, como hoje).
- Ligar armadilha a arquivo/ferramenta (não há âncora hoje; seria heurística de texto).

## Anti-metas

- Um agente ganhando `earned`/`longTerm` para a própria memória com um sinal que ele forja sozinho mais facilmente do
  que hoje.
- O daemon passando a ler transcript ou arquivo do agente.
- Números de definições diferentes apresentados como comparáveis.
- Arquivamento em massa por mudança de regra (o relógio do prazo por tipo não pode acelerar de surpresa).

## Sinais de evidência (pergunta 1)

| Sinal | Agentes | Custo | Falso positivo | Falso negativo | Forjável pelo agente? |
|---|---|---|---|---|---|
| **(a) leitura depois da injeção** (`memory.get` de id já injetado na sessão) | Claude, Cursor (MCP) | ~zero: o handler já sabe o id e o chamador | baixo (pediu o corpo inteiro de propósito) | altíssimo: 13 buscas/7d; a linha injetada já traz até 300 caracteres do corpo, então raramente há motivo para `get` | sim, uma chamada |
| **(b) citação na resposta** (id curto `[xxxxxxxx]`/8 hex ou título normalizado na última mensagem do turno) | Claude (Stop); Codex manda mensagem mas não recebe injeção; Cursor sem hook | baixo: a mensagem já chega no `turn.completed`; comparar com ≤ 5 ids pendentes | médio: eco do id sem uso real; título genérico casando por acaso | alto: o agente usa a memória sem nomeá-la (o comum) | sim, digitar o id |
| **(c) ferramenta toca o caminho** (`PostToolUse` Read/Edit/Write/Grep com `file_path`/`path` = `map.path`) | só Claude | baixo: payload já chega em `work.hook` | alto: a memória foi escolhida por ser relevante ao que o agente ia tocar de qualquer jeito (prova relevância, não uso) | — | sim, um Read |
| **(d) `memory flag --useful`** | Claude, Cursor | já existe | baixo | altíssimo: 0 em 7 dias | sim, já hoje |

Leitura honesta:

- **Todos são forjáveis** pelo agente, porque todos vêm dele. Nenhum é pior que (d), que já existe e já conta uso. A
  proteção não está no sinal, está nas regras em volta, que continuam valendo: id tem de estar injetado **nesta**
  sessão; um uso por (dia, sessão) por id; `earned` exige 2 sessões e 2 dias; `longTerm` exige o portão do curador; só
  registro com proveniência verificada é injetado e pode ganhar uso. Hoje o implícito não exige **nenhuma** ação do
  agente; qualquer sinal acima é estritamente mais caro de forjar.
- **Autopromoção.** O único caso realmente novo: o terminal que **escreveu** a memória citá-la. Proposta: evidência
  vinda da mesma sessão que criou o registro não conta (a proveniência guarda `origin` = `<terminal> (<preset>)`; a
  sessão de criação pode ir no evento `created`). Ver Minhas chamadas.
- **(c) fica fora agora:** 0 mapas no projeto e o sinal mede relevância. Volta depois do item 7, se houver mapas.
- **Recomendação: (b) + (a) + (d)** como "uso com evidência"; (b) é o único com volume plausível.

## Dois contadores (pergunta 2)

- **`LifecycleEntry.evidencedUses: Set<UseKey>?`**, opcional (arquivo antigo decodifica; ausente = vazio). Um `UseKey`
  por (dia UTC, sessão), como `usefulUses`. Nunca entra sem o implícito correspondente também entrar: evidência **e**
  sem correção. Consequência: `evidencedUses ⊆ usefulUses` (invariante testável).
- **Implícito mantido igual** (`usefulUses`, `resolvePending`): a linha de base continua comparável.
- **Como (b) chega lá:** no `turn.completed`, o roteador compara a mensagem com os ids pendentes da sessão
  (`lifecycle.pending`) e guarda num conjunto do ator `cited[terminal]` só os ids citados (sem texto). No próximo prompt,
  `resolvePending` sem correção faz `addUse` como hoje e `addEvidence` para `pendentes ∩ cited`. Correção: nada, como hoje.
  `endSession` limpa `cited`.
- **(a) adiado ao próximo prompt** (decisão do coordenador, 2026-11-18, sobrepõe a versão anterior que contava na hora):
  `memory.get` de id em `injectedBySession` (e elegível) **não** chama `addUse`; marca o id em `cited[terminal]` com o
  tipo `get`, como a citação. No próximo prompt, `resolvePending` sem correção grava a evidência junto do uso implícito
  que já existe hoje (só se o id estiver pendente); correção: nada. Assim um `get` sozinho não move nada que as regras
  leem e não abre caminho novo de autopromoção.
- **(d)** conta na hora, como já fazia antes deste item (`--useful` → `addUse`), agora com `addEvidence` junto.
- **Evento.** `used` ganha `evidenced: [UUID]?` (subconjunto de `ids`) e `evidence: [String]?` paralelo (`cite`|`get`|`flag`).
  `cite` e `get` vão no `used` do próximo prompt (um id citado e lido aparece duas vezes, uma por tipo); só `flag` emite um
  `used` próprio, com `where = flag`, que a precisão v1 ignora. Linha antiga decodifica (campos opcionais).

Que regra usa o quê:

| Regra | Fase 1 (sombra) | Fase 2 (proposta, decisão do dono) |
|---|---|---|
| `earned` | implícito, igual a hoje | implícito como hoje **e** ≥ 1 `evidencedUses` |
| `longTerm` (8 usos/4 dias/14 dias + portão) | implícito, igual | implícito como hoje **e** ≥ 3 `evidencedUses` em ≥ 2 dias; portão continua |
| precisão | v1 (implícito) + v1 de evidência, lado a lado | igual |
| índice por uso (item 5) | `usefulUses.count` | (`evidencedUses.count`, `usefulUses.count`) |
| prazo por tipo (item 6) | relógio zera com uso implícito | **continua** zerando com implícito (sem arquivamento em massa) |
| mérito do item 4 (adiado) | — | dias distintos de `evidencedUses` na janela, quando acordar |

## Transição sem destruir nada (pergunta 3)

- **As 183 `earned` ficam `earned`.** O tier gravado já é pegajoso (`tier(for:)` só reavalia `provisional`), então a
  Fase 2 só muda a passagem provisional → earned. Nenhum evento, nenhuma linha de digest, nada arquivado.
- **Rótulo de mérito, sem tier novo:** `LifecycleEntry.earnedBy: String?` = `implicit`|`evidence`, gravado na passagem a
  `earned`. Ausente = anterior à mudança (conta como `implicit`). `memory stats` mostra `earned` por rótulo. Tiers
  continuam só em `lifecycle.json`.
- **Carência:** não precisa de período em que as duas regras valem: a Fase 1 inteira é a carência (só mede). A Fase 2
  liga por uma constante (`LifecycleRules.evidenceRequired`); desligar volta à regra antiga para as provisórias, sem
  tocar nas já gravadas.
- **longTerm:** hoje 0, então não há nada a transicionar. O portão do curador continua o único caminho.
- **Reversível:** nenhuma mudança apaga campo; `memory.undo` da promoção segue igual (`promotionUndone`). Daemon antigo
  reescrevendo o arquivo **perde** `evidencedUses`/`earnedBy` (chaves desconhecidas são descartadas no encode): risco
  aceito, mesmo comportamento dos campos aditivos anteriores.
- **Proveniência:** nada muda no livro. Evidência só existe para ids injetados, que já exigem `isVerified`.

## Efeito esperado nos números (pergunta 4)

Medido agora (`collie memory stats --since 7d --json`, daemon 0.1.0): 1005 prompts, 605 com memória (60%), 13 buscas
com 97 resultados, 0 flags `useful`, tiers 47 provisional / 183 earned / 0 longTerm, 7 correções.

Não deu para medir: a precisão implícita (o daemon instalado não emite `used`) e qualquer taxa de citação (o log de
eventos e `lifecycle.json` em `~/Library/Application Support/Collie` dão `Operation not permitted` no sandbox; o daemon
não guarda as mensagens).

Estimativas, a confirmar na Fase 1:

- **Precisão implícita:** ≈ 1 − (correções + último prompt de cada sessão) ÷ candidatas ≈ **90–99%**. Não discrimina.
- **Leitura (a):** < 1% das candidatas (13 buscas por semana inteira, contra milhares de ids injetados).
- **Citação (b):** desconhecida. Agentes raramente repetem ids hex; título aparece mais. Chute: **2–15%** das candidatas.
- **Precisão com evidência esperada: ~3–15%.** Discrimina, mas é dura: se a Fase 2 ligasse hoje, poucas provisórias
  chegariam a `earned`. Por isso a Fase 2 só com ≥ 14 dias de sombra e com o número na mão.

## Interação com o item 1 e o item 7 (pergunta 5)

- **Ordem:** (1) instalar um daemon com a Leva 1 (sem isso nenhuma precisão existe); (2) Fase 1 deste item; (3) ≥ 7 dias
  de sombra; (4) piso do item 1 (feat/mem-floor, `1908916`); (5) comparar a precisão **com evidência** antes/depois do
  piso: é ela que deve subir quando o piso corta memórias fracas; a implícita fica perto de 100% nos dois casos.
  Se o piso entrar antes, anotar a data e comparar só janelas inteiras de um lado.
- **Item 7** (mapas com âncora, `feat/mem-design`): independente. Ambos adicionam campo opcional a `LifecycleEntry`
  (`mapAnchors` lá, `evidencedUses`/`earnedBy` aqui): conflito só textual. O sinal (c) depende de existirem mapas.
- **Versão da métrica.** `usage.precision` ganha `def: 1` (a definição da Leva 1, inalterada). O bloco novo
  `usage.evidence` nasce com `def: 1`. Qualquer mudança de definição sobe o `def`; o painel mostra "–" para tendência
  que cruza `def` diferente. Mudança de comportamento (piso) não muda `def`, mas é anotada no spec de linha de base com a
  data de instalação.

## Custo e superfície de ataque (pergunta 6)

- **O daemon não lê nada novo do disco.** A mensagem do turno já chega pelo `turn.completed`, extraída pelo hook no
  contexto do próprio agente. Limite: comparar no máximo os primeiros 64 KiB (como `maxPromptBytes`) contra ≤ 5 ids
  pendentes: busca de 8 hex e título normalizado (minúsculas, sem acento, espaços colapsados; só títulos com ≥ 3
  palavras para não casar "Build quebrado" por acaso).
- **Em disco:** `evidencedUses` (dia, sessão) e `earnedBy` em `lifecycle.json` (0600); no log, ids e a palavra do tipo.
  **Nenhum trecho da mensagem persiste**; `cited` vive no ator e some no reinício (perde no máximo um turno de
  evidência). `lastTurn` (500 caracteres, já existente) não muda.
- **Abuso:** um agente mandando `turn.completed` falso com ids. Precisa do token dele, só cita ids injetados na sessão
  dele, conta uma vez por (dia, sessão), e continua sujeito às regras de tier e ao portão. Mesmo poder que `--useful` já dá.

## Abordagens

- **A. Contador paralelo em sombra, regra depois (recomendada).** Mede primeiro, muda regra com dado. Nada quebra a base.
- **B. Trocar o implícito pela evidência já.** Precisão discrimina no dia seguinte, mas `earned` quase para e o item 6
  arquiva provisórias em massa; sem base para escolher limiares.
- **C. Curador julga uma amostra de usos.** Sinal melhor, mas gasta o limite diário e lê texto da conversa (contra a
  meta de privacidade).

## Riscos

- Citação natural baixa demais (≪ 3%): a Fase 2 deixa `earned` quase inatingível. Mitigação: decidir só com os dados;
  alternativa é exigir evidência só para `longTerm`.
- Pedir citação ao agente infla o sinal e mede obediência, não uso.
- Eco do id: o agente repete `[abcd1234]` ao resumir a injeção. Mitigação possível: não contar citação numa resposta que
  cita **todas** as pendentes (mede, decide na Fase 2).
- Downgrade do daemon descarta os campos novos.
- As 183 `earned` legadas nunca saem: o frio de 60 dias olha `lastReadAt`, que a própria injeção renova. Fora do escopo;
  vale um item próprio.

## O que muda no spec 2026-11-13 (quando cada fase entrar)

- Fase 1: seção **Signals → Useful use** ganha o parágrafo "uso com evidência (sombra)"; **State** lista
  `evidencedUses`; **Observability** cita `usage.evidence` e o `def`.
- Fase 2: tabela **Tiers** (colunas earned/longTerm com a exigência de evidência e `earnedBy`); **Calls** troca "Passive
  'no correction' counts as use" pela regra nova; índice por uso (item 5) com a nova ordem.

## Minhas chamadas (conferir)

1. Sinais: (b) citação + (a) `get` + (d) `--useful`. (c) adiado até existirem mapas.
2. Evidência só soma junto com o implícito (exige também "sem correção"): `evidencedUses ⊆ usefulUses`.
3. Fase 1 só mede, ≥ 14 dias; a Fase 2 é decisão sua, com os números.
4. Fase 2 proposta: `earned` = regra atual + ≥ 1 evidência; `longTerm` = regra atual + ≥ 3 evidências em ≥ 2 dias.
5. Prazo por tipo continua zerando com uso implícito (evita arquivar em massa). Alternativa: só com evidência.
6. Evidência da mesma sessão que criou a memória não conta (anti-autopromoção). Precisa gravar a sessão no `created`.
7. Não pedir ao agente que cite memórias no Stop.
8. Título casa só com ≥ 3 palavras; id por 8 hex.
9. `cited` só em memória do ator (some no reinício).
10. As 183 `earned` ficam como estão, rotuladas `implicit` por ausência; nada reavaliado.

## Ordem sugerida

1. Instalar daemon com a Leva 1 (dependência; fora deste item).
2. Fase 1 (tarefas 1–6 abaixo, em qualquer ordem entre si exceto 3 depois de 1–2).
3. ≥ 7 dias de sombra → piso do item 1 → ≥ 7 dias.
4. Decisão do dono → Fase 2 (tarefas 7–8).

## Tarefas independentes (lista, não plano)

1. `LifecycleEntry.evidencedUses`/`earnedBy` opcionais + `LifecycleStore.addEvidence`; teste: arquivo antigo decodifica,
   invariante ⊆.
2. Função pura `UseEvidence.cited(message:records:) -> Set<UUID>` (8 hex, título normalizado ≥ 3 palavras, 64 KiB);
   testes de casamento e não casamento.
3. `turn.completed` preenche `cited[terminal]` a partir de `lifecycle.pending`; `resolvePending` grava evidência;
   `endSession` limpa; `used` ganha `evidenced`/`evidence`. Teste: correção não grava; sem citação não grava.
4. `memory.get` de id em `injectedBySession` → uso + evidência `get`. Teste: id não injetado não conta.
5. `--useful` grava também evidência `flag`. Teste.
6. `memory stats`: `usage.precision.def`, `usage.evidence {def, candidates, evidenced, rate, byKind}`, por agente e
   tendência; painel "Uso com evidência". Teste no `MemoryObservability`.
7. (Fase 2) `LifecycleRules.evidenceRequired` + regras earned/longTerm + `earnedBy` na passagem; ordem do índice.
   Testes puros de tier.
8. Atualizar spec 2026-11-13 e a linha de base (cada fase no seu commit).
9. (Depois do item 7, se houver mapas) sinal (c) no `work.hook`.

## Verificação

- Cada tarefa com seu teste, rodado por `--filter` (nunca a suíte inteira).
- Fase 1 em produção: `collie memory stats --json` mostra `usage.evidence` com `candidates` igual ao da precisão v1 e
  `evidenced ≤ used`; `lifecycle.json` com `evidencedUses ⊆ usefulUses`; nenhum tier mudou (`earned` por rótulo igual
  ao total anterior).
