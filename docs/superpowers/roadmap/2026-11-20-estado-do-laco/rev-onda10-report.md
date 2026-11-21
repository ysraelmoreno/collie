# Revisão Onda 10 (cc84ce4..ec56615), somente leitura

**Bloqueia a instalação? Não.** Nenhum achado perde dado, queima tentativa, trava o laço ou abre leitura de transcript. Três
achados devem ser corrigidos antes do push: o falso agrupamento da M10.4 (A1), um nome interno num teste público (A2) e o escopo
do `work usage --terminal` (A3).

Método: `git diff cc84ce4..HEAD` e `git show HEAD:<arquivo>` (a árvore de trabalho não foi usada como referência). Rodei
`scripts/ci/lint.sh` (`lint ok`) e `scripts/ci/check-architecture.sh` (`ok`). Depois, `git status` mostra só `.collie/`. Não rodei
build nem testes.

## Achados, do mais grave ao menos

### A1. M10.4: o critério `subject` (e o de título) agrupa memórias distintas; a colapsada some pela sessão inteira
- `Sources/CollieDaemonKit/Memory/InjectionDedup.swift:19`: `if a.subject == b.subject { return true }`, sem olhar `kind` nem escopo.
- `MemoryStore.save` (`MemoryStore.swift:60-63`) já substitui pelo subject quando kind, scope, paddock e lotId são iguais. Então duas
  memórias **ativas** com o mesmo subject só existem quando são de **tipo ou escopo diferentes**: uma decisão e uma armadilha sobre o
  mesmo assunto, uma de projeto e uma do lote, uma de cercado e uma de projeto. Esse é exatamente o caso que o critério agrupa.
- Cenário: a decisão "usar --filter" e a armadilha "--filter com '$' casa demais" têm o mesmo subject. No bloco de relevantes
  (`MemoryService.swift` ~733) entram todos os tipos. A de pontuação menor é colapsada e vai para `injected[terminal]` (~752), então
  não volta **na sessão inteira**, mesmo quando um prompt fala só dela.
- O critério de título (Jaccard ≥ 0,5 sobre `significantTerms`, termos de 3 letras ou mais) é agressivo com títulos curtos: dois
  termos comuns em três já colapsam ("Build compartilhado quebrado" × "Build compartilhado lento" = 2/4). Ele também ignora o `kind`.
- O comentário do `near` diz "normalized subject", mas o código compara o valor cru. O save normaliza, mas um registro antigo ou
  importado pode não estar normalizado.
- Os testes não pegam isso: o commit 48c24a7 trocou os fixtures para um subject por registro, e nenhum teste tem um par distinto
  (mesmo subject e tipo diferente, ou títulos curtos parecidos) que **não** deve colapsar.
- Confirmação: leitura de `MemoryStore.save`, `InjectionDedup.near/collapse` e `MemoryService.hits/contextParts/checklistParts`.
- Correção: exigir o mesmo `kind` (e a mesma loja/escopo) em todos os critérios; pedir ≥ 3 termos comuns ou um limiar maior no
  título; um teste com decisão + armadilha de mesmo subject e um com títulos curtos distintos (os dois entram).
- Severidade: **corrigir antes do push**.

### A2. Nome interno e formato de caminho pessoal num teste público
- `Tests/CollieDaemonKitTests/TurnSafetyTests.swift:78`:
  `URL(fileURLWithPath: "/Users/someone/Documents/codes/my-orchestrator-memory/.collie/paddocks/collie")`.
- `my-orchestrator-memory` é o nome do checkout local. Em cc84ce4, `git grep` só achava esse nome num relatório em `docs/`; o
  teste é novo, então a ocorrência entrou nesta onda. Fere a regra do repositório público.
- Correção: um caminho neutro de mesmo comprimento (o teste só mede o limite de 1500 caracteres), por exemplo
  `/Users/dev/Documents/codes/projeto-exemplo-12345/.collie/paddocks/collie`.
- Severidade: **corrigir antes do push**.

### A3. M10.3: `work usage --terminal <guiado>` lê os resumos fechados de outro cercado
- `Sources/CollieDaemonKit/WorkCommands.swift` (`case "work.usage"`, ~450). O escopo dos fechados é o `paddockId` de `target()`, e
  `target()` aceita `--terminal` de qualquer terminal ao alcance da guia. `work.history` (M7.1, ~404-414) usa sempre
  `caller.paddockId`.
- Os abertos ainda passam por `visible` (terminais ao alcance). Os fechados só passam pelo filtro de cercado.
- Cenário: um Pastor faz `summon --paddock <cercado que ele criou>` (ShepherdCommands ~113-119) e fica com o filho na guia. Com
  `work usage --terminal filho` ele lê os títulos e os números de **todos** os trabalhos fechados daquele cercado, inclusive os de
  terminais que ele não alcança.
- O dado é pouco sensível (títulos e contagens, sem texto de conversa), mas foge do "mesmo escopo do `work history`" da spec. O
  teste `workUsageReadsTheClosedWorksOfItsOwnPaddockOnly` cobre só o terminal no pasto (escopo nil), não o `--terminal`.
- Correção: com caller, usar `caller.paddockId` para os fechados (como `work.history`), ou filtrar os fechados por
  `seen.contains(UUID(terminalId))`.
- Severidade: **corrigir antes do push** (risco baixo).

### A4. M10.4: colapsada no mesmo livro que injetada gera retratação de algo que o agente nunca viu
- `MemoryService.swift:314` e `:752` põem as colapsadas em `injected[terminal].ids`. `retractions` (~617-650) varre esse mapa.
- Cenário: uma colapsada é substituída ou marcada errada durante a sessão. O agente recebe "Não vale mais: <título>" sobre uma
  memória que nunca entrou no prompt, e o evento `retraction` a conta.
- Correção: um conjunto `seen` separado, que o filtro de candidatas lê e as retratações ignoram.
- Severidade: **nit** (ruído e métrica, nada se perde).

### A5. M10.2: o pré-check roda à toa em dois casos
- `AttemptMachine.swift` (`commitSeen` com `hasPrecheck`).
  - (a) **Turno estourado:** depois de `turnTimedOut` com commit, o pré-check roda até 180 s, e `precheckNudge` então devolve
    `waitExpired` (`rest < 1`). Esse tempo de orçamento não serve para nada, e o pré-check roda junto com um agente que pode ainda
    estar trabalhando: o próprio código diz "a turn past its timeout may still be working". Os dois mexem no mesmo `.build` da
    worktree (a armadilha do build compartilhado).
  - (b) **Segunda rodada:** com `prechecked == true` o resultado não muda nada (passou ou falhou, segue para o check). Ele só grava
    no diário, ao custo de um build a mais.
- Não queima tentativa nem trava: as duas rodadas são limitadas (uma cutucada por tentativa) e o cancelamento cai em
  `measureFacts → cancelled`. Conferi todos os eventos possíveis em `.turn` depois da cutucada: `turnEnded`, `turnTimedOut`,
  `turnFailed`, `usageLimit` e `waitExpired` terminam em check ou em uncount.
- Correção: um flag `timedOut` no estado para pular o pré-check; na 2ª vez, ir direto ao check. A spec fala em "falhar de novo",
  então a 2ª rodada é escolha do dono.
- Severidade: **nit**.

### A6. M10.5: a correção depende de um detalhe interno do SwiftUI, e o menu `…` não tem teste
- `Sources/CollieApp/TerminalNodeView.swift:482-499` (`unzoomed`). A localização é reescrita para casar com a conta de deslocamento
  que o SwiftUI faz hoje (o comentário `ponytail:` admite isso: macOS 14/15). Se uma versão do macOS corrigir essa conta, a
  correção passa a deslocar o clique duas vezes. `TerminalFullscreenClickTests` (zoom 0,7 e 1,5) pega isso, desde que rode
  naquela versão.
- Campos: `NSEvent.mouseEvent(...)` mantém tipo, modificadores, timestamp, janela, `eventNumber`, `clickCount` e `pressure`. Perde
  `subtype`, `stage` (force click), `associatedEventsMask` e `trackingNumber`. Só down/up passam por ele. `mouseDragged` do
  `TitleHost` usa `deltaX/deltaY` do evento original e não chama `super`, e o clique direito usa o evento original. Então arrasto,
  menu de contexto e duplo clique (o `clickCount` é preservado) não regridem.
- Lacuna: a spec pede para conferir o menu `…` e o Reiniciar. Não há teste do `…`, um `Menu` com `.borderlessButton` que pode ser
  um controle AppKit dentro do host. Antes da correção ele funcionava com zoom (o dono usava "Tela cheia" do menu), o que sugere
  que ele não passa pela conta quebrada. Se ele recebe o evento reescrito, pode ter **regredido**. Não dá para confirmar sem rodar.
- Nos testes, os eventos vão direto ao alvo de `hitTest` (não por `NSWindow.sendEvent`). Isso não depende de janela chave, o que é
  bom para CI, mas não é o caminho real do app.
- O ponto do botão está fixo (`size.width - 46`, "achado varrendo no zoom 1"). Se o layout mudar, o teste fica vermelho (falha
  falsa positiva, não silenciosa).
- Correção ou desenho: (1) um teste do `…` em zoom 0,7, ou uma conferência manual pelo dono antes do push; (2) para não depender do
  SwiftUI, deixar o `TitleHost` sem escala (como os painéis, só `frame`), em vez de reescrever eventos.
- Severidade: **corrigir antes do push** só a conferência do `…` (manual ou teste); o resto é **nit**.

### A7. M10.4: custo do agrupamento no checklist
- `checklistParts` agrupa **todas** as armadilhas ativas com hits (`ChecklistRanking.pick(..., max: recs.count)`), não "≤ 50"
  como diz o `ponytail:` do `collapse`. `near` refaz `significantTerms` dos dois títulos a cada par: O(n²) tokenizações dentro do
  ator `MemoryService` a cada início ou compactação de sessão. Também lê os vetores de todas elas.
- Correção: calcular os termos uma vez por registro e parar quando houver `max` mantidas (mais uma folga).
- Severidade: **nit**.

### A8. M10.3: total parcial quando o resumo é cortado
- `WorkArchive.tokens` soma as tarefas do arquivo. Se `fitted()` cortou "a última metade das tarefas" (resumo acima de 1 MB), o
  total mostrado no modal e em `work usage` fica menor, sem aviso.
- Severidade: **nit**. Ou gravar o total no topo do resumo, ou marcar "parcial" quando `truncated`.

### A9. Asserções vazias ou fracas nos testes
- `ArchiveUsageTests.swift` (fim): `#expect(!out2.contains("SEGREDO"))`, mas nenhum fixture tem "SEGREDO": a asserção passa sempre.
- `InjectionDedupTests.checklistCollapsesAndStatsCountIt` monta o evento `injected` com `collapsed` à mão. Nenhum teste confere que
  a injeção real emite `collapsed`.
- `PastorContextLifecycleTests.handoffFileIsWritten…` usa um `paddock` que não está no workspace, então a parte "memórias novas, só
  título" da passagem nunca passa pelo caminho do daemon (só por `Handoff.text`).
- Severidade: **nit**.

### A10. Documentação
- O limiar da M10.4 (Jaccard 0,5, cosseno 0,92) está só no código; `docs/feature-map.md` e `docs/referencia.md` não falam do
  dedupe nem de `work usage --id`.
- Severidade: **nit**.

## Áreas examinadas sem achado (e como)
- **M10.2, máquina e intérprete:** li `AttemptMachine.reduce` inteiro em HEAD e as linhas novas de `WorkLoop` (`runPrecheck`,
  `precheckNudge`, `left`, `talk`).
  - Uma cutucada por tentativa (`prechecked`). `turnFailed` depois da cutucada não falha nada. O caminho cancelado cai em
    `measureFacts → .cancelled → uncount`.
  - Resumo depois de queda: o commit é adotado sem agente, então sem pré-check.
  - Sem `--precheck`, as guardas novas não mudam nada (`hasPrecheck == false`). O teste de tabela cobre isso, e
    `withoutAPrecheckNothingChanges` mostra `commands == ["true"]`.
  - O pré-check roda pelo mesmo `host.check` do check (mesmo sandbox) e na mesma worktree. O comando aparece no cartão do dono
    (`loopCardText`), e um `--precheck` vazio é recusado.
  - O rabo da saída passa por `ANSI.strip`, `RerailText.plain` e `LotBoards.scrub`, com limite de 40 linhas e 3 KB.
  - Prompt: as duas linhas fixas estão lá, e há teste de ≤ 1500 caracteres.
- **M10.1, contexto:** `lastContext` lê só o rabo (≤ 256 KB, com `lines(maxBytes: 512 KB)`).
  - Caminho por `TranscriptChunk.allowed` + `lstat` regular. `open` usa `O_NOFOLLOW|O_NONBLOCK` e confere com `fstat` (FIFO não
    trava). Primeira linha cortada é ignorada. Do JSON ficam só os três contadores, nenhum texto. Linhas de sidechain ficam de fora.
  - Sem divisão; tokens < 0 viram 0. Arquivo ausente ou que cresce durante a leitura: nil, sem aviso.
  - O texto do aviso é fixo por nível. Só a medida de `pastorContext` vai para o log de eventos (números, id da sessão), e só no Stop
    sem pergunta de memória.
- **M10.1, passagem de turno:**
  - Arquivo pelo id do cercado, gravado por temporário e `rename`, com 0600 numa pasta 0700, ≤ 4 KB (`bounded`).
  - Leva só shas curtos validados como hex; nunca assunto de commit nem saída do check (o teste usa um segredo nos dois). As memórias
    vão só por título e id curto; ficam de fora as de lote e as de outro cercado (`visible`). A próxima onda sai com caminho relativo
    ao repositório.
  - `work handoff` lê só o cercado de quem chama.
- **M10.3, compatibilidade:** `Attempt`/`Task` decodificam tolerantes (um campo errado vira nil), e o teste com arquivo antigo e
  arquivo estranho passa por leitura.
  - Imutabilidade: o resumo continua escrito uma vez no fechamento; `work usage` só lê. O limite de 500 eventos/1 MB segue por
    `fitted()`, com teste de 600 eventos.
  - Os segundos por tentativa saem do diário (sem relógio novo).
  - O modal mostra os tokens só quando existem.
- **M10.4, repositório intocado:** só leitura do store e do índice (`vectors` é um SELECT). O teste compara os `.md` antes e depois.
  Sem embedder, `vecs` fica vazio e sobram subject e título, sem falha.
- **Testes (`git diff -- Tests/`):** nenhum `sleep`, `asyncAfter` ou relógio de parede usado para temporização (o `Date()` novo é dado
  de fixture). `TerminalFullscreenClickTests` espera por continuation.
  - `ContextAdviceTests` perdeu 4 testes (limite em MB, janela, caminhos recusados, texto fixo). Todos voltaram, por tokens, em
    `PastorContextLifecycleTests`: níveis exatos, janela por nível, symlink/FIFO/fora de projects, texto sem conteúdo.
  - `ChecklistTests` trocou oito títulos quase iguais por títulos distintos: adaptação legítima, porque aqueles eram duplicados de
    verdade. Os demais testes alterados só registram o comando ou parâmetro novo.
  - O fake (`LoopFakeHost`) aplica a regra real: o pré-check roda de verdade em git e shell temporários.
  - Os 15 commits de sondagem da M10.5 não deixaram arquivos: o teste final é um só.
- **`scripts/laco-check.sh`** (inalterado nesta faixa): conferi as 78 suítes da lista com `git grep "(struct|class) <nome>"` em
  `Tests/`. Todas existem, sem nomes colados. Há casos M10.1 a M10.5, mas cada um só checa se o arquivo de teste existe (igual aos
  anteriores).
- **Regras do repositório público:** fora o A2, o diff não traz caminho pessoal nem nome interno (`git grep` por `/Users/` e pelo nome
  do checkout).

## Melhorias de fluxo e de desenho (fora dos achados)
1. M10.5: deixar o `TitleHost` sem escala (só `frame`, como os painéis), em vez de reescrever o `NSEvent`. Isso corrige a causa sem
   depender da conta interna do SwiftUI e conserta também hover e tooltips sob zoom.
2. M10.4: guardar "vista" e "injetada" em dois conjuntos; agrupar só dentro do mesmo `kind`; pré-calcular os termos; registrar no
   evento `injected` o par (colapsada → representante), para medir falso agrupamento em `memory stats`.
3. M10.2: guardar no estado como o turno terminou (estouro ou não), para pular o pré-check sem saída. Dá para pensar num
   `precheckSkipped` no diário.
4. `laco-check.sh`: os casos M10.x podiam conferir um símbolo além do arquivo (como M1.1 faz com `grep -q stopReason`), para uma
   tarefa não passar com um arquivo de teste vazio.
5. A M10.5 gastou 15 commits de sondagem no branch. Para a próxima, sondar numa worktree descartável e commitar só o teste vermelho
   e a correção deixa o histórico legível.
