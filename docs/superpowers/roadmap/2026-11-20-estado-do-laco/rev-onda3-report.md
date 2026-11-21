# Revisão independente: Onda 3 do estado do laço (`247d0e2..HEAD`, 18 commits, 50 arquivos)

**Bloqueia a instalação? Sim.** Com o daemon sandboxando terminais, que é o único modo em que `--parallel` é aceito, a faixa não consegue nascer: `git worktree add` roda sob o perfil do laço do cercado, e esse perfil não deixa escrever nem `<repo>/.collie/paddocks/lane-*` nem `<common>/worktrees/lane-*`. O recurso documentado falha em toda tarefa, e nenhum teste exercita esse caminho.

Revisão somente leitura. Nada rastreado foi editado, não houve commit, push, `kill` nem toque no daemon ou no app. O build ficou em `.build/rev-onda3`.

---

## Achados (do mais grave ao menos)

### 1. BLOQUEIA: sob o sandbox real, nenhuma faixa é criada e nenhuma é removida
- **Onde:** `Work/WorkLoopLanes.swift:151-153` (`cut` chama `LaneWorktree.create(..., host: host)`, e `host` é o `RouterLoopHost` **do cercado**). Também `Work/LaneWorktree.swift:83` (`git worktree add -b … <path> <base>`), `Sandbox/SandboxProfile.swift:162-175,187` (o perfil estrito do laço) e `WorkLoopCommands.swift:75` (`--parallel > 1` exige `config.sandboxHome`).
- **O que está errado:** o git do laço sempre roda com `sandbox-exec -f <perfil do laço>` (`GitRunner.swift:31-33`, via `loopGit`). Esse perfil é `SandboxProfile.render` com `project` = worktree do cercado e `worktreeGitDir` = `<common>/worktrees/<cercado>`. Ele nega toda escrita (`(deny file-write*)`, linha 162) e depois só reabre:
  - o projeto (a worktree do cercado);
  - em `<common>`, apenas `objects`, `refs`, `logs`, `packed-refs` e o gitdir **do cercado**;
  - temp, caches e homeWrites.

  O `git worktree add` precisa criar `<repo>/.collie/paddocks/lane-<w8>-<t>` (irmã do cercado, fora do projeto) e `<common>/worktrees/lane-<w8>-<t>/`. As duas escritas são negadas. O `worktree remove --force` e o `worktree prune` também são, o que afeta o fim do laço e o varredor de início (`removeLanes(prepare:)` roda sob o mesmo perfil).
- **Cenário:** `collie work run --parallel 2` num cercado com tarefas que têm `--scope`. Em cada tarefa, `cut` lança "git worktree failed: … could not create … Operation not permitted". `noLane` então adia a tarefa ("a faixa não pôde ser criada") e devolve o `used`. O laço termina `finished` com tudo adiado.
- **Como confirmei:** leitura das regras na ordem em que o Seatbelt as avalia (a última que casa decide; é o mesmo modelo de `ProfileRules` em `LaneHostTests.swift:15-80`). Não executei: `sandbox-exec` não aninha aqui (`sandbox_apply: Operation not permitted`, rc=71), e por isso `checkOfALaneRunsUnderTheLaneProfile` foi pulado.
- **Por que os testes não pegam:**
  - O `Rig` de `LaneHostTests` cria as faixas com `LoopFakeHost` sem perfil (linhas 100-102).
  - `LoopParallelTests` e `LoopParallelE2ETests` usam hosts falsos sem sandbox (`E2EHost`, linhas 97-99 e 123).
  - Nenhum teste aplica ao **perfil do cercado** a pergunta "escreve `<paddocks>/lane-x` e `<common>/worktrees/lane-x`?".
- **Correção sugerida:** criar e remover a faixa com o git do próprio daemon fora do perfil do laço, como o `PaddockManager` faz com os cercados (hooks e fsmonitor desligados pelo `GitRunner`, em caminhos que o daemon mesmo gera e valida). Outra saída é um perfil de "gerente de faixas" que abra só `<paddocks>/lane-*` e `<common>/worktrees/lane-*`. Somar um teste de regressão com `ProfileRules` sobre o texto de `prepareLoopSandbox(work, paddock:)`, conferindo essas duas escritas e o `remove`.

### 2. Corrigir antes do push: o integrador apaga edições do dono feitas durante o gate
- **Onde:** `Work/LaneIntegrator.swift:44-49` (`othersWorking` e a sujeira são medidos **uma vez**, antes do merge), `:66-78` (o gate pode rodar até `checkTimeout`, 30 min) e `:78,83-88` (`restore` = `reset --hard <merged|before>` + `clean` dos não rastreados que não estavam em `loose`).
- **O que está errado:** depois do gate não há nova checagem. O motor sequencial faz essa checagem: `AttemptMachine.swift:167-170` passa por `.awaitOthers` antes de `.settle(reset:)`, e só reseta com `who == nil`; com árvore suja usa `settle(reset: false)`. Aqui o reset roda sempre.
- **Agravante novo da Onda 3:** `loopReaching` (`WorkLoopCommands.swift`) exclui o **starter**. No modo sequencial o starter costuma esperar. No paralelo o trabalho acontece nas faixas, e o Shepherd fica livre para editar a worktree do cercado enquanto o gate roda ali.
- **Cenário:** a faixa A passa e o integrador faz o merge e começa o gate (`swift test`, minutos). O dono, ou o seu Shepherd, edita `Sources/X.swift` e cria `notas.md` no cercado. Quando o gate termina, `reset --hard merged` desfaz a edição rastreada e o `clean` apaga `notas.md` (não estava em `loose`). Perda silenciosa.
- **Como confirmei:** leitura dos dois caminhos e comparação com a tabela da `AttemptMachine`.
- **Correção sugerida:** antes do `restore`, medir de novo `othersWorking` (incluindo o starter) e a diferença em relação a `merged`. Se alguém trabalha ou mexeu em algo, não resetar: devolver `.wait` e parar com `dirtyTree`/`othersWorking`, como o motor faz. Melhor ainda, ver o item 9.a.

### 3. Corrigir antes do push: a faixa pode mover qualquer branch do repositório (refs do `.git` comum)
- **Onde:** `Sandbox/SandboxProfile.swift:169-171`. Para uma worktree, o perfil abre `<common>/refs`, `<common>/logs`, `packed-refs(.lock)` e `objects` **inteiros**. As regras da faixa (`laneClosed`, linhas 120-122 e 198-201) fecham só a worktree do cercado e as outras `lane-*`. O `.git` comum não entra.
- **O que expõe:** o agente da faixa (e o check e o git dela) pode rodar `git update-ref refs/heads/collie/<cercado> <sha>`, ou mexer em `main`, `refs/remotes/*`, `refs/stash`, reescrever `packed-refs`, e até apagar o reflog (`logs` também é gravável). Com isso ele contorna o integrador e o gate. Consequências:
  - O cercado fica com índice ≠ HEAD.
  - O integrador vê sujeira e o laço para com `dirtyTree`.
  - O branch do dono pode ter sido movido para um commit que ninguém julgou.
- **O que fica fechado (confirmado):**
  - `hooks`, `config`, `config.worktree`, `info/attributes`, `commondir`, `worktrees/*/{commondir,gitdir,config.worktree}` e o `.git` da faixa (`SandboxProfile.swift:229-236`).
  - O integrador e todo git do laço rodam com `core.hooksPath=/dev/null` e `core.fsmonitor=false` (`GitRunner.swift:29`), e os filtros do repositório são desligados (`loopGit`).
  - Um hook plantado pela faixa **não** chega ao integrador.
- **Leitura:** "fechado para leitura" vale só para os **arquivos da árvore**. O object store comum continua legível, então os commits do cercado e das outras faixas podem ser lidos (`git show collie/lane/<outra>:arquivo`). O que fica escondido de fato são os arquivos não commitados do dono.
- **Mesma classe** de qualquer terminal de worktree (é anterior a esta onda), mas a spec da faixa promete isolamento.
- **Como confirmei:** leitura da ordem das regras. Nenhuma regra posterior nega `refs/` para a faixa.
- **Correção sugerida:** no perfil da faixa, abrir só `refs/heads/collie/lane/<nome>` (e `.lock`), `logs/refs/heads/collie/lane/<nome>`, `logs/HEAD` e `objects`, e deixar `packed-refs` fechado. Pelo menos documentar o limite em `docs/referencia.md`.

### 4. Corrigir antes do push (ou documentar): `--budget` estoura até N× com faixas
- **Onde:** `Work/WorkLoopLanes.swift:136-139` (o `spent` só cresce quando a faixa **termina**), `WorkLoop.left` (`budget − spent − elapsed próprio`) e `WorkLoopLanes.swift:207` (o timeout do gate do integrador vem do `loop` lido no início da faixa).
- **O que está errado:** cada faixa recebe como teto o orçamento inteiro que sobrava quando ela começou, sem descontar o tempo das outras faixas que estão rodando.
- **Cenário:** `--budget 600 --parallel 4`, quatro tarefas longas começando com `spent=0`. Cada uma pode rodar 600 s, e o laço gasta 2400 s.
- **Como confirmei:** o próprio teste `theSharedBudgetSpentByOneLaneStopsTheOther` (`LoopParallelTests.swift:310-330`) afirma `spent >= 100` com `budget: 50`. O estouro é o comportamento testado. A spec (`m3-5`, item 3) pede que "o orçamento restante de cada faixa venha do mesmo `spent`".
- **Correção sugerida:** o escalonador guarda o `since` de cada faixa viva, e `left` desconta `Σ elapsed` de todas. Ou um vigia que cancela as faixas quando `spent + Σ elapsed ≥ budget`.

### 5. Corrigir antes do push: o varredor remove faixas de **outro daemon** (ou um branch do dono `collie/lane/*`)
- **Onde:** `WorkLoopCommands.swift` (`removeLanes`: `active: others`, todos os trabalhos menos este) e `Work/LaneWorktree.swift:113-135` (`orphans` + `remove`: `worktree remove --force` e `branch -D`).
- **O que está errado:** no fim de **qualquer** laço paralelo, e no início do daemon, é removida toda faixa cujo `work8` não esteja no registro **deste** daemon. Um daemon de desenvolvimento e o instalado no mesmo repositório (situação real neste projeto, que roda os dois no mesmo checkout) têm registros diferentes. O fim de um laço no daemon A apaga com `--force` as faixas vivas do laço do daemon B. O mesmo vale para um branch que o dono tenha chamado `collie/lane/…`, ou uma worktree do dono com esse branch, que perde o trabalho não commitado.
- **Como confirmei:** leitura. Hoje está mascarado pelo achado 1 (sob o sandbox, o `remove` também falha).
- **Correção sugerida:** no `loopEnded`, remover só as faixas com `work8 == w`. Para órfãs de trabalho desconhecido, exigir um marcador escrito pelo daemon dono (por exemplo, o id da raiz do Collie num arquivo do gitdir da faixa) e nunca usar `--force` numa worktree que não tenha esse marcador.

### 6. Nit: cancelamento do daemon e integração em andamento
`cancelLoops` espera `loopCancelWait` e depois chama `removeLanes`. A integração roda numa `Task` própria, não cancelada (`WorkLoopLanes.swift:210-212`), e pode estar com o gate rodando. A faixa é removida no meio do merge e do gate. O `restore` pode não acontecer, porque o daemon está saindo, e a worktree do cercado fica num estado intermediário (merge feito, gate sem veredito). É raro, mas é exatamente o "nunca deixa a worktree do cercado em estado intermediário" do `m3-4`.

### 7. Nit: arquivos ignorados do dono no cercado
`git merge` sobrescreve sem avisar arquivos **ignorados** que estejam no caminho (por exemplo, a faixa commita um `.env` ignorado no cercado). Depois, `reset --hard before` (`LaneIntegrator.swift:84`) remove esse arquivo, que passou a ser rastreado em `merged`. O arquivo original do dono se perde. O motor sequencial tem a mesma classe de problema. Fica registrado.

### 8. Nits menores
- **MCP:** `needs` e `scope` são lidos com `str(r, …)` (`WorkCommands.swift:256`). Um cliente MCP que mande um array JSON tem o valor **descartado em silêncio**. Sem `needs`, a tarefa pode começar antes da sua dependência. Melhor recusar quando o tipo não for string.
- **Nomes:** `namesTaken()` é lido antes do `summon`. Um terminal do dono criado nesse intervalo faz o summon recusar o nome, e a tentativa falha por isso. É raro e não afeta a segurança.
- **Teste:** `LaneIntegrationTests` tem uma espera ativa limitada com `Task.sleep(.milliseconds(1))` (até 5000 voltas). É o único `sleep` novo, só em teste; o lint cobre só `Sources/`.
- **Orçamento:** `spent` conta também o tempo na fila do integrador (FIFO), o que é coerente com "tempo das faixas", mas não está documentado.

---

## Áreas examinadas sem achado (e como)

- **Perfil da faixa: caminhos, symlinks e injeção.**
  - Os caminhos passam por `realPath` (`/var` → `/private/var`).
  - O regex das irmãs `lane-*` é escapado com `re()` e as strings com `q()`.
  - O id da tarefa é validado por `^[A-Za-z0-9._-]{1,40}$` sem `..` (`LaneWorktree.validate`, também em `work.run` para todas as tarefas abertas). Não há metacaractere que chegue ao `.sb`.
  - `subpath` da faixa `lane-x` não cobre `lane-x2`.
  - `vetLane` exige formato de faixa, gitdir de worktree e o mesmo `common` do cercado, e recusa a própria worktree do cercado, `other`, `repo` e uma pasta sem worktree (`LaneHostTests.onlyALaneOfThePaddocksRepositoryGetsALaneProfile`).
  - A spec é lida do cercado.
  - **Sandbox desligado:** o host da faixa recusa `git`, `check` e `summon` (`RouterLoopHost.profile`, `laneHostRefusesWithoutTheSandbox`), e `work run --parallel` é recusado (`WorkLoopCommandTests`).
- **Integrador: merge e desfazer** (fora o achado 2).
  - Só faz merge com a árvore limpa (`--untracked-files=no`) e ninguém trabalhando.
  - Em conflito: `merge --abort` + `reset --hard before` + `clean` só do que é novo. Os não rastreados do dono (`loose`) ficam.
  - `reset` só para `before` ou `merged`, que o próprio integrador mediu.
  - Sem push. Só o branch checado em `dir` muda.
  - É FIFO (`busy` mais continuações) e está testado (`LaneIntegrationTests`).
- **Escalonador.**
  - `used` é incrementado antes de a faixa começar, e `--max` usa `prefix(max − used)`.
  - `noLane` e `release` devolvem o `used`.
  - `tries` só é escrito pela faixa da tarefa (um `alive` por id).
  - Uma tarefa reaberta durante a integração continua em `integrating` e depois em `alive` até o `.ended`, sem corrida que a reescalone duas vezes.
  - Escopo sobreposto e tarefa sem escopo (exclusiva) nunca rodam juntos, e a exclusiva "fecha a porta" (`TaskScheduler.ready:26-38`).
  - `needs` exige `done` e fora de `integrating`.
  - Ciclo é recusado no `task add` (`needsRefusal`), e um ciclo ou dependência adiada vira adiamento em `deferBlocked` (o laço termina).
  - `--parallel` fora de 1…4 é recusado (`num` exige ≥1, max 4; teste com 0 e 5).
  - Parar o laço cancela, espera todas e cada uma remove a sua faixa numa `Task` própria (`dropLane`).
- **`--parallel 1`.** `parallel <= 1` cai no `while` antigo, sem passar por `runLanes`. Os testes antigos mudaram **só** nomes (`loop-a-1` → `w-task-a-t1`/`trabalho-a-t1`), conferido com um diff normalizado. As outras mudanças:
  - `resumeAt = Date() + 1` e o commit com data de 5 s atrás, por causa da regra M2c do mesmo segundo;
  - um `||` que virou `&&` (asserção **mais forte**, teste (g));
  - "nenhum terminal `loop-*`" que virou contagem por id (`loopAgentsLeft`);
  - novos casos (`parallel` 0 e 5, `--parallel` sem sandbox).

  Nenhuma asserção foi removida sem substituta, e não há `sleep` nem relógio de parede novos nos testes antigos.
- **M3.8, nomes.**
  - `grep 'loop-'` em `Sources` não acha mais nenhum reconhecimento por prefixo.
  - O varredor de início usa `WorkJob.terminal` (UUID), com o nome do job como fallback só quando não há terminal registrado (trabalho antigo, ou queda entre o summon e a escrita), e sempre no mesmo cercado.
  - `othersWorking` e `loopSharesWorktree` usam o `cwd` do terminal, não o nome.
  - O `dismiss` é por UUID.
  - O slug deixa só `[a-z0-9-]`, sem `-` nas pontas, com até 48 caracteres. `../`, quebra de linha e `--paddock` viram `-`/`paddock`.
  - A unicidade compara sem caixa contra os terminais, os painéis e os `launching` (`-2…-9`, depois o id curto).
  - O nome vai como valor JSON em `args`, nunca em shell, perfil ou caminho.
- **Compatibilidade de arquivo.**
  - Em `WorkTask.init(from:)`, `needs` e `scope` do tipo errado viram nil (sem escopo é o lado seguro: a tarefa roda sozinha).
  - Em `WorkLoopState`, `parallel` e `lanes` são lossy, e `LaneState` tolera `phase`/`attempt` desconhecidos.
  - `WorkJob.terminal` é lossy.
  - `LoopEvent.lane` é opcional, e um evento malformado cai no `Lossy`.
  - `WorkPanelTests.decodesALoopWithLanesAndWithout` cobre o painel.
  - CLI: `--needs` e `--scope` repetíveis se juntam por vírgula (`ArgvParser:37`). `Commands.swift` está coerente.
- **M2c.** `resumeAt = adopt ? task.resumeAt : nil`. Ao deixar a tentativa só se grava com `resumeAt == nil`, e o varredor também só grava quando está ausente. A adoção usa `ct < floor(resumeAt)`, o lado conservador. O commit `32a5bb0` não tem nenhum `reset` nem `clean` novo (o grep só acha comentários).
- **Portões.**
  - `swift test --disable-sandbox --skip MemoryEventEmissionTests --filter 'TaskSchedulerTests|LaneWorktreeTests|LaneHostTests|LaneIntegrationTests|LoopParallelTests|LoopLaneLifecycleTests|LoopParallelE2ETests|AgentNamingTests|LoopResumeNitsTests|LoopResumeSafetyTests|WorkLoopTests|LoopCancelTests|AttemptMachineTests'` → **"Test run with 169 tests in 13 suites passed"** (EXIT=0). O único pulado foi `checkOfALaneRunsUnderTheLaneProfile` (sandbox aninhado).
  - `scripts/ci/lint.sh` → `lint ok`.
  - `scripts/ci/check-architecture.sh` → `ok`.

## O que os testes e2e NÃO provam
- O git real **sob o perfil real**: lanes, removal e sweep sempre rodam com host falso ou sem perfil. É o achado 1.
- O Seatbelt de verdade na faixa: o único teste está desabilitado dentro de um terminal de agente. Precisa rodar fora do sandbox, por exemplo no CI ou num terminal do dono.
- O summon real de um agente na faixa (`ShepherdCommands.summon(lane:)`, `ProjectRoot.resolve`), o cartão e o `startMode .strict` com um app real.
- A concorrência do dono no cercado durante o gate do integrador (achado 2).
- Dois daemons no mesmo repositório (achado 5).

## Melhorias de fluxo e desenho (fora dos achados)
- **a. Gate fora da árvore do dono:** integrar numa worktree temporária destacada em `merged` (ou rodar o gate na própria faixa depois de `git merge <HEAD do cercado>` dentro dela). Só depois de o gate passar, fazer `merge --ff-only` no cercado. Isso elimina todo `reset --hard` e `clean` na worktree do cercado e resolve os achados 2, 6 e 7 de uma vez.
- **b. Teste de perfil por "intenção":** para cada operação de git que o laço faz (criar e remover faixa, merge, commit na faixa), uma tabela `ProfileRules` dizendo quais caminhos ela escreve. Teria pegado o achado 1 e protege o achado 3.
- **c. Teste fora do sandbox:** um alvo de CI (ou `scripts/laco-check.sh`) que rode `checkOfALaneRunsUnderTheLaneProfile` e um e2e pequeno com o `RouterLoopHost` real fora de um terminal sandboxado.
- **d.** Documentar em `docs/referencia.md` que `--budget` com `--parallel` é soma do tempo das faixas (e, até corrigir, que pode estourar) e que a faixa vê os commits de todas as branches.
