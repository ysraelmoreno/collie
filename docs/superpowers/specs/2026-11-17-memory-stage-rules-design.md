# Memória, leva 3: regras de estágio (vagas por mérito, mapa que acompanha o código, ciclo de vida da global) — design

Data: 2026-11-17. Status: rascunho para aprovação. Nada implementado. Itens 4, 7 e 8 das 8 melhorias de memória pedidas
pelo dono. O item 8 depende de uma decisão do dono (ver "Minhas chamadas").

## Intenção e porquê

O ciclo de vida (spec 2026-11-13-memory-lifecycle) dá estágio por uso: provisória → conquistada → longo prazo. Três buracos:

- **4.** As 12 vagas de longo prazo por projeto, uma vez cheias, ficam congeladas: uma memória muito mais usada nunca entra,
  e uma de longo prazo que ninguém usa mais nunca sai.
- **7.** Um `map` ("o arquivo X faz Y") só sai quando o caminho some. O arquivo pode ser reescrito e o mapa continua sendo
  injetado como verdade.
- **8.** A global fica fora do ciclo de vida: nada mede se ela é usada, e uma global ruim vive pelas regras antigas.

Restrições do dono: nada apagado (tudo arquivado e reversível); estágio só vem do `lifecycle.json`; não quebrar o livro de
proveniência (`MemoryProvenance.swift`); cada mudança com teste (só os testes tocados, via `--filter`); atualizar o spec
2026-11-13 quando uma regra mudar.

## Estado atual (conferido no código, HEAD de feat/doc-memory, 1d290a2)

- **Vagas.** `MemoryService.applyVerdict` (`MemoryService.swift:806`), caso `.verifyPromotion`: `promote = longTerm <
  LifecycleRules.maxLongTermPerProject` (12, `LifecycleRules.swift:11`). `longTermCount(near:)` conta registros `active` do
  repo com `tier == .longTerm` **gravado** (um longTerm contestado mantém a vaga). Sem vaga, o portão grava `gatedAt = now`
  e a candidata espera 14 dias (`verifyCooldown`) para tentar de novo.
- **Gasto inútil hoje.** O passo (3) do `LifecyclePass` enfileira o portão (`enqueuePromotion`, ≤ 3/dia via `takeGate`) sem
  olhar se há vaga: com as 12 cheias, cada candidata gasta uma chamada do curador que não pode promover nada.
- **Desfazer promoção.** `undoDigest` da linha `promovida` (`MemoryDigest.swift:128`): para cada `before`, longTerm →
  earned, `gatedAt = now`, `promotionUndone = true` (nunca mais portão automático). Laço sobre **todos** os `before`.
- **Eventos.** `MemoryEvent.Kind` já tem `promoted` e `demoted`; `demoted` hoje só sai quando um longTerm é contestado
  (`LifecyclePass.swift:57`, `applyFlag` em `MemoryService.swift:776`). `memory.stats` conta `promotions`/`demotions`.
- **Uso.** `usefulUses: Set<UseKey{day, session}>`, nunca podado; `renderLongTerm` ordena por `usefulUses.count`.
- **Mapa.** `MemoryRecord` guarda `kind`, `path` (`.map` apenas, relativo ao repo), título, corpo, datas; nenhum commit.
  `RepoMemory.present` (`MemoryService.swift:56`) esconde um map cujo caminho sumiu; `MemoryCleanup.plan` arquiva após 7
  dias sumido (`archiveMissingPath`); `ClaimChecks` dá `pathMissing` no mesmo caso. Nada compara conteúdo.
- **Git do daemon.** `GitFactsLive` roda `GitRunner.run` com 10 s de limite, `core.hooksPath=/dev/null` e
  `core.fsmonitor=false`; o passo de consolidação **não** roda sob `GitRunner.$sandbox` (só pedidos de terminal em modo
  aberto). Comentário ponytail do `GitRunner`: filtros, `sshCommand`, `gpg.program` plantados ainda rodam.
- **Claim checks.** Passo (4): no máximo 10 contestações por passada; um texto já re-checado (`recheckedAt ≥ updatedAt`)
  **nunca mais** é checado. Sem curador, uma checagem falha **arquiva** (`enqueueVerify`, `MemoryVerify.swift:95`).
- **Global.** Mora em `<root>/memory` (dados do Collie, `config.paths.root`), fora do repo; índice em `<root>/cache`.
  `lifecyclePass` sai cedo para ela (`store.root == nil`) e `LifecycleRules.eligible` exige `scope == .project`. Mas a
  consolidação diária **já** roda `MemoryCleanup.plan` na global: arquiva fria (60 dias sem leitura, `lastReadAt` do
  índice), nota baixa e duplicatas. Ou seja, a global **já tem** poda por falta de uso, por tempo. A injeção grava os ids
  globais em `injectedBySession` (dá para marcar), mas não cria `pendingUse` (filtro `eligible`): global nunca soma uso útil.
  `mark` não põe `(provisória)` em global.
- **Decisão registrada.** 2026-11-13-memory-lifecycle-design.md, Não metas: "Global, lot and paddock scopes: no automatic
  promotion (user decision). They keep today's rules."

## Metas

- 4: vaga cheia não congela o longo prazo; troca só com vantagem clara e rara; nada de portão gasto sem chance de promover.
- 7: um mapa cujo arquivo mudou muito desde que foi escrito é **contestado** e vai ao curador; nunca arquivado sozinho.
- 8: ver opções (decisão do dono).

## Não metas

- Mudar números das regras existentes (21 dias, 8 usos, 12 vagas, 3 portões/dia).
- Mapa: detectar renomeação (caminho sumido já é tratado pelo `pathMissing`/`archiveMissingPath`).
- Promoção automática de global, lote ou paddock (decisão do dono, mantida).
- Lote: **não entra** em nenhum dos três itens.
- Mexer no livro de proveniência: nenhum item escreve nele nem muda como ele verifica.

## Anti-metas

- Um agente (ou memória plantada) despejar uma longTerm boa com uma marcação.
- Troca de vaga em gangorra (A entra, B sai, B volta…).
- Um `git diff` rodando driver externo ou `textconv` plantado no repo.
- Mapa arquivado só porque o arquivo mudou.

## Abordagens

### Item 4 (vagas)

- **A. Mérito por usos totais** (`usefulUses.count`). Simples, mas `usefulUses` nunca é podado: a mais antiga sempre vence;
  é exatamente o congelamento que se quer tirar.
- **B. Mérito por dias distintos com uso nos últimos 30 dias** (desempate: usos totais, depois `tierSince` mais antigo
  perde). Mede uso recente e resiste a rajada num dia só (vários usos num dia contam um).
- **C. Rotação por idade** (a longTerm mais velha sai). Ignora uso. Descartada.
- **Recomendo B**, com histerese (abaixo).

### Item 7 (mapa)

- **A. Âncora no `.md`** (campo `commit` no frontmatter). Descartada: o `.md` é gravável por agente em sandbox; daria para
  "re-ancorar" e calar a checagem, e mudaria o texto que a proveniência e o `textHash` medem.
- **B. Âncora no livro de proveniência.** Descartada: o livro responde "o daemon escreveu este texto?"; misturar estado de
  checagem nele cria escrita fora de `MemoryStore.write` e arrisca o que o dono pediu para não quebrar.
- **C. Âncora no `lifecycle.json`**, por id e por `textHash`. Arquivo do daemon (0600, fora do repo), já por id e já
  independente de loja (pasto e worktrees). **Recomendo C.**

### Item 8 (global)

Ver "Minhas chamadas": opções A (nada novo), B (poda de provisória sem uso), C (B + estágio conquistada sem tag).

## Design

### Item 4: vagas de longo prazo por mérito

**Mérito** (`LifecycleRules.merit(e, now)`, puro): número de dias UTC distintos em `usefulUses` nos últimos 30 dias
(`meritWindow`). Ordem total: (mérito, `usefulUses.count`, `tierSince` mais antigo = menor).

**Quem pode ser deslocada** (a "mais fraca"): longTerm **gravada**, `eligible`, **não contestada agora** (um contestado
espera o veredito; se contestada pudesse sair, uma marcação despejaria uma memória boa: anti-meta), longTerm há pelo menos
30 dias (`minTenure`). A de menor mérito entre essas.

**Quando troca** (histerese, tudo precisa valer):
1. As 12 vagas cheias (contagem de hoje, inalterada).
2. `merit(candidata) ≥ merit(mais fraca) + 2` (`displaceMargin`). Margem em dias, não proporção: números pequenos.
3. Nenhuma troca nesse projeto nos últimos 7 dias (`displaceEvery`). Guardado no `lifecycle.json`: `lastDisplacedAt`
   por loja (`[storeKey: Date]` no `State`, opcional, arquivos antigos decodificam).
4. A deslocada não volta por 30 dias: `gatedAt = now` + `displacedAt = now` na entrada; o passo (3) só re-portão depois de
   `minTenure` contado de `displacedAt` (e ainda precisa vencer a margem). Fecha a gangorra.

**Portão sem desperdício.** Passo (3) do `LifecyclePass`: antes de `enqueuePromotion`, se o projeto está cheio e a
candidata não vence a mais fraca pelas regras 2–3, **não** enfileira nem grava `gatedAt` (fica tentando a cada passada,
de graça). Isso já reduz o gasto de hoje mesmo sem troca.

**No veredito** (`applyVerdict`, `.verifyPromotion` válido): reavalia na hora (o estado pode ter mudado na fila). Vaga livre →
promove como hoje. Cheio e ainda vence → numa única escrita do `LifecycleStore`: candidata longTerm (`tierSince`,
`textHash`), mais fraca `tier = .earned`, `tierSince = now`, `gatedAt = now`, `displacedAt = now`; `lastDisplacedAt[loja]
= now`. Cheio e já não vence → igual hoje (fica earned, `gatedAt = now`).

**Eventos.** `promoted` da candidata (como hoje) + `demoted` da deslocada com `verdict: "displaced"` (o campo `verdict` já
existe nos eventos de ciclo de vida; o `demoted` de contestação continua sem verdict). `memory.stats` ganha
`displacements` (contagem de `demoted` com esse verdict); `demotions` continua contando os dois.

**Digest e desfazer.** A troca é uma unidade. Duas linhas com o mesmo `job` (o id do job de verify): `promovida` (before =
[candidata], razão cita a deslocada) e nova ação `rebaixada` (before = [deslocada], razão "deslocada por \"…\" (usos
recentes: X vs Y dias)"). Desfazer **qualquer uma** desfaz a troca: candidata → earned + `promotionUndone = true` (o
caminho de hoje), deslocada → longTerm de volta (se ainda `eligible`, mesmo `textHash`, não contestada; senão fica earned e
o digest diz por quê), `displacedAt = nil`. O `undoDigest` de `promovida` hoje itera todos os `before`: com a linha separada
ele não marca a deslocada como "desfeita pelo usuário" por engano. `eventKind("rebaixada") = .demoted`.

**`promotionUndone`.** Inalterado: nunca é candidata, nunca desloca ninguém. Uma longTerm deslocada **não** recebe
`promotionUndone` (foi a regra, não o usuário).

**`maxGatesPerDay`/`verifyCooldown`.** Inalterados. A troca só acontece dentro de um portão válido (curador cheio), então
gasta o mesmo orçamento de hoje, e menos (regra do portão sem desperdício).

**Hoje longTerm = 0.** Nada muda até um projeto encher as 12 vagas: com vaga livre o caminho é o de hoje, byte a byte.
Única mudança visível antes disso: nenhuma. (A regra de portão sem desperdício também só age com o projeto cheio.)

**Testes** (`LifecycleRulesTests`, `MemoryVerifyTests`, `MemoryDigestTests`, só os tocados): mérito com rajada num dia;
margem 1 não troca, 2 troca; contestada nunca é alvo; `minTenure`; `displaceEvery`; gangorra (deslocada tenta voltar em 10
dias e não consegue); veredito que chega depois de a vaga abrir; desfazer `promovida` e `rebaixada` restauram as duas;
portão não enfileirado com projeto cheio e candidata sem vantagem.

### Item 7: mapa que acompanha o código

**Âncora.** `LifecycleEntry` ganha `mapAnchors: [String: String]?` (`textHash` → SHA do commit), no máximo 4 (como as
versões da proveniência), para o mesmo id com textos diferentes no pasto e numa worktree. Gravada pelo `LifecyclePass`
(passo 4) quando um `map` `eligible` com `path` não tem âncora para o seu `textHash`: `git rev-parse --verify HEAD` da raiz
da loja. Âncora "preguiçosa": o primeiro valor é o HEAD da primeira passada, não o do momento em que o mapa foi escrito
(mudança anterior à âncora não é vista; aceito, conservador). Texto editado → hash novo → âncora nova (o mapa foi
reescrito, presume-se olhando o código). A âncora só avança em dois casos: texto novo, ou veredito `valid` do curador
(abaixo). Nunca por passada comum: assim pasto e worktree não ficam se re-ancorando um ao outro.

**"O arquivo mudou".** Só commit contra commit, nunca a árvore de trabalho (sem filtros clean/smudge; edição em andamento
não conta):

`git diff --numstat --no-ext-diff --no-textconv --no-renames <âncora> HEAD -- <path>`

pelo `GitRunner` com o limite de 10 s do `GitFactsLive`, mais `-c diff.external=` por garantia. `--no-ext-diff` e
`--no-textconv` fecham o vetor de driver plantado em `.gitattributes`/config (o passo roda fora do sandbox). Uma chamada
por **âncora distinta** cobre todos os mapas ancorados nela (vários `-- p1 p2 …`, até 50 caminhos por chamada).

**Limiar.**
- Arquivo: linhas mudadas (adicionadas + removidas) ≥ `max(40, 40% das linhas do arquivo em HEAD)`. Linhas em HEAD: tamanho
  lido do disco só se o arquivo não for maior que 1 MB (senão só o absoluto). Binário (`-\t-` no numstat): ignorado.
- Diretório: arquivos distintos mudados ≥ `max(5, 30% dos arquivos rastreados sob ele)` (`git ls-files -- <dir>`, contado).
- Caminho sumido: não é deste item (fica com `pathMissing`).
- Erro, timeout, âncora inalcançável (rebase, clone raso) ou raiz que não é repo: **desconhecido**, nunca falha. Âncora
  inalcançável é substituída pelo HEAD atual (sem contestar).

**Resultado.** Novo `ClaimFailure.Kind.mapDrift` com detalhe `"<path> +A −R desde <sha8> (P%)"`. Entra pelo mesmo caminho
do passo (4): marcação `outdated` de sessão `claim-check`, `contestedNow`, `(contestada)` na injeção, re-checagem
enfileirada. **Diferença:** `mapDrift` é falha *branda*: não conta para o arquivamento sem curador de `enqueueVerify`
(hoje "sem modelo + checagem falha = arquiva"). Sem curador, o mapa fica contestado e, após 14 dias, vai para "Precisa de
você" (passo 8, como hoje). Ou seja: nunca arquivado sozinho.

**O curador.** O payload de verify ganha, como fato (dado, dentro do delimitador com nonce), a linha do numstat e até 5
assuntos de `git log --format=%s --no-show-signature <âncora>..HEAD -- <path>` (cada um ≤ 120 caracteres, texto de commit é
dado). Sem conteúdo do arquivo nesta leva (custo e superfície; ver "Minhas chamadas"). Veredito `valid`: o caminho de hoje
(flags limpas, `recheckedAt`) **e** âncora do `textHash` atual = HEAD. `invalid`: arquivado pelo curador (reversível,
`memory.undo`), como hoje.

**O pulo do re-checado.** Hoje o passo (4) pula para sempre um texto com `recheckedAt ≥ updatedAt`. Para `mapDrift`, o pulo
vale só pelo `verifyCooldown` (14 dias): depois disso o drift é medido da âncora nova, então não re-contesta pelo mesmo
motivo. As outras checagens mantêm o pulo de hoje.

**Pasto e worktrees.** O commit é do repositório (worktrees compartilham objetos), então a âncora gravada no pasto existe na
worktree. Cada loja compara âncora → o seu HEAD; numa worktree a deriva é a do branch dela. Uma contestação vale para o id
(entrada única), venha de qual loja vier: consistente com o resto do ciclo de vida.

**Custo por passada** (uma vez por dia por loja): 1 `rev-parse HEAD` + 1 `diff --numstat` por âncora distinta (na prática
1–3) + 1 `ls-files` por mapa-diretório + 1 `git log` só por mapa contestado (≤ 10, o teto de contestações). Teto
explícito: no máximo 50 mapas checados por passada, os de checagem mais antiga primeiro (`mapCheckedAt` na entrada).

**Testes** (`ClaimChecksTests`, `LifecyclePassTests`, repositório de fixture): abaixo do limiar não contesta; acima
contesta; binário ignorado; diretório; âncora inalcançável re-ancora sem contestar; texto editado ancora de novo; sem
curador **não** arquiva (só contesta); veredito válido avança a âncora; driver externo plantado em `.gitattributes` não
roda (o teste conta que o comando do driver nunca executou); pasto e worktree com textos diferentes guardam duas âncoras.

### Item 8: ciclo de vida para a global

Não desenhado como decidido: depende da pergunta 1 em "Minhas chamadas". O que vale para qualquer opção que mexa:

- **Onde mora o estado.** O mesmo `<root>/learning/lifecycle.json`: já é por id e já vive nos dados do Collie, onde a global
  também mora. Nada no `.md` da global. `store = "global"` (a `RepoMemory.key` dela).
- **O que é "uso".** Injeção por relevância de prompt da global em **qualquer** projeto, resolvida na próxima mensagem sem
  correção nem marcação `wrong`/`outdated`: o mesmo `pendingUse` de hoje, só deixando de filtrar a global. Leitura do índice
  (`lastReadAt`) é o que a regra fria de hoje já usa; não muda.
- **Prazo.** 21 dias como a provisória de projeto é curto para uma global (vale para todos os projetos, aparece menos em
  cada um). Recomendo 45 dias desde `max(tierSince, último uso útil)`, relógio começando na primeira passada (migração não
  arquiva nada), e só para memórias **não** do usuário (`usersKind`, pinned e reviewed ficam fora, como no projeto).
- **Reversível.** Mesma linha `aposentado` no digest com Desfazer, evento `archivedUnused`.
- **Passada.** Um `globalLifecyclePass` curto (sem git, sem claim checks, sem promoção): migração, uso → `earned` (só se
  opção C), poda. Chamado na consolidação da global (hoje sai cedo).
- **Lote:** não entra.

## Ordem sugerida de implementação

1. **Item 7** primeiro: único com efeito hoje (mapas já existem; longTerm = 0), e não depende do dono.
2. **Item 4**: dormente até um projeto encher 12 vagas. Pode esperar `memory.stats` mostrar algum projeto com ≥ 9 longTerm;
   a parte "portão sem desperdício" é barata e pode ir junto.
3. **Item 8**: só depois da resposta do dono.

## Tarefas independentes (lista, não o plano)

- T1 (7) `LifecycleEntry.mapAnchors` + `mapCheckedAt`, opcionais; decodificação de arquivo antigo.
- T2 (7) `GitFacts.mapDrift(anchor:paths:)` com os flags seguros e o limiar; fixture com driver plantado.
- T3 (7) `ClaimFailure.mapDrift` no passo (4), teto de 50, pulo de re-checado por 14 dias para drift.
- T4 (7) `mapDrift` brando em `enqueueVerify`; fatos no payload de verify; veredito válido avança a âncora.
- T5 (4) `LifecycleRules.merit` e escolha da mais fraca (puro).
- T6 (4) portão sem desperdício no passo (3).
- T7 (4) troca em `applyVerdict`, `lastDisplacedAt`, `displacedAt`, evento `demoted/displaced`, `stats.displacements`.
- T8 (4) linha `rebaixada`, desfazer da troca como unidade.
- T9 (8, após decisão) uso útil para global, `globalLifecyclePass`, poda.
- T10 atualizar 2026-11-13-memory-lifecycle-design.md (ver abaixo), uma vez por item implementado.

## O que muda no spec 2026-11-13-memory-lifecycle-design.md

- Tabela de estágios, linha longTerm: "at most 12 per project" passa a "12 por projeto; cheio, uma candidata com ≥ 2 dias de
  uso recente a mais desloca a mais fraca não contestada (≥ 30 dias na vaga, ≤ 1 troca por projeto a cada 7 dias)".
- "Demotion": acrescenta "deslocada por mérito → earned, sem `promotionUndone`".
- "Signals (A) / Claim checks": acrescenta o drift de `map` (âncora no `lifecycle.json`, limiar, falha branda).
- "Re-check (C)": "archived only if a deterministic claim check also failed" passa a excluir `mapDrift`.
- Não metas (só se o dono escolher B ou C no item 8): "Global … keep today's rules" vira "Global: sem promoção; poda de
  provisória sem uso em 45 dias (decisão do dono, 2026-11-…)".

## Riscos

- **Mérito errado.** 30 dias e margem 2 são chute; com poucas promoções não há dado. Mitigação: números em `LifecycleRules`,
  `stats.displacements` para ajustar.
- **Drift barulhento.** Arquivo central reformatado contesta todos os mapas dele; até 10 contestações por passada, cada uma
  uma chamada do curador. Mitigação: limiar alto (40 linhas/40%), teto de contestações existente, orçamento do curador
  coloca correções primeiro.
- **Git fora do sandbox.** O ponytail do `GitRunner` já admite que config plantada (filtros etc.) roda. Este item só usa
  commit contra commit com `--no-ext-diff --no-textconv`, que não aciona filtros nem drivers; `gpg.program` não roda com
  `--no-show-signature`. Risco residual igual ao das claim checks de hoje.
- **Global (B/C).** Uma global útil mas rara (uma vez a cada dois meses) seria arquivada; reversível, mas some da injeção até
  alguém desfazer.
- **Proveniência.** Nenhum item escreve no livro nem altera `isVerified`; a troca de vaga e a âncora não reescrevem `.md`,
  então o `sha256` gravado continua batendo. Teste de regressão: depois de troca e de âncora, `isVerified` continua true.

## Minhas chamadas (conferir)

1. **Item 8, pergunta ao dono (bloqueia o item).** O spec de 2026-11-13 registra sua decisão: global "sem promoção automática;
   mantém as regras de hoje". As regras de hoje **já** podam global por falta de uso: arquivada fria após 60 dias sem leitura.
   Podar por "uso útil" é regra nova, não promoção. Pela letra ("mantém as regras de hoje"), muda o que você decidiu; pelo
   espírito (o medo era promover), não. Qual você quer?
   - **A. Nada novo.** A poda fria de 60 dias já existe. Zero código. (Minha recomendação se o incômodo era "global ruim vive
     para sempre": ela não vive.)
   - **B. Poda de provisória sem uso útil em 45 dias**, além da fria de hoje. Sem estágio, sem tag, sem promoção.
   - **C. B + estágio "conquistada"** para global (deixa de ser podada por B), ainda sem longo prazo.
2. Mérito = dias distintos com uso nos últimos 30 dias, margem 2, 30 dias mínimos na vaga, 1 troca por projeto a cada 7 dias.
3. Longo prazo contestada nunca é deslocada (espera o veredito).
4. Desfazer qualquer linha da troca desfaz a troca toda; a deslocada não ganha `promotionUndone`.
5. Âncora do mapa no `lifecycle.json`, preguiçosa (HEAD da primeira passada), por `textHash`.
6. Só commit contra commit (edição não commitada não conta).
7. Limiar 40 linhas ou 40% (arquivo), 5 arquivos ou 30% (diretório); binário ignorado.
8. `mapDrift` nunca arquiva sem curador; vai a "Precisa de você" em 14 dias.
9. O curador recebe numstat e assuntos de commit, **não** o conteúdo do arquivo. Se os vereditos saírem ruins (o curador não
   tem como julgar sem ver o código), a próxima leva pode mandar até 4 KB do diff.
10. Global (se B/C): 45 dias, não 21.
11. Lote fora de tudo.
12. Ordem 7 → 4 → 8; item 4 pode esperar algum projeto chegar a ~9 longTerm.

## Verificação

- Cada tarefa com seu teste, rodado só com `swift test --filter <Suite>` dos testes tocados (nunca a suíte toda).
- Item 7: fixture git com commits reais (abaixo/acima do limiar, binário, diretório, âncora perdida, driver plantado).
- Item 4: testes puros com relógio injetado (`now:`) para margem, posse mínima, intervalo e gangorra; desfazer pelo digest.
- Regressão: com vaga livre e sem mapas, o `LifecyclePass` produz o mesmo `lifecycle.json` e o mesmo digest de antes.
- `memory.stats` mostra `displacements` e as contestações `mapDrift` contadas em `contestedOpen`.
