# Revisão independente: Onda 3c (`7402095..0719153`, 7 commits, M3c.1–M3c.4)

**Bloqueia a instalação? Não.** Nenhum caminho novo apaga trabalho do dono: o `reset --hard` agora só roda quando os arquivos rastreados estão exatamente como o integrador os deixou, e arquivo não rastreado nunca é apagado. Antes do push há dois pontos. Primeiro, um `work.wait` cujo cliente já morreu continua contando como "o starter só espera" por até 1 h. Segundo, o teste novo de avisos usa `sleep` e relógio de parede, contra a regra da onda, e a asserção negativa dele pode passar sem provar nada.

Revisão somente leitura, toda feita no commit (`git show 0719153:…` e `git diff 7402095..0719153`). Não rodei `swift build`/`swift test`. Os checks cumulativos do laço já tinham passado e entram aqui só como evidência de que os testes estão verdes. Escrevi só este arquivo. As cópias das fontes ficaram no scratchpad da sessão.

---

## Achados (do mais grave ao menos)

### 1. Corrigir antes do push (M3c.2): um `work.wait` órfão ou em segundo plano faz o starter que está editando passar por "só esperando"
- **Onde:** `Sources/CollieDaemonKit/WorkCommands.swift:338-341` (`ownWaitBegan` com `defer`) e `:326-329` (`work.status`). `Sources/CollieDaemonKit/WorkLoopCommands.swift:401-407` (`loopAnyoneWorking`/`loopStarterWaits`). `Sources/CollieDaemonKit/UnixSocket.swift:160-174`: `process` chama `halt()`, que suspende a leitura do socket, e roda o handler em `Task.detached`. Uma desconexão do cliente não é vista e o handler não é cancelado.
- **O que está errado:** a contagem (`openRequests == ownWorkWaits[work] > 0`) mede pedidos abertos no daemon, não um cliente vivo, e ignora o selo `working`. O handler do `work.wait` só termina por mudança no trabalho ou pelo próprio timeout (padrão 600 s, máximo 3600 s, `WorkCommands.swift:417`). Enquanto isso o starter conta como "só esperando" e fica fora do `who`, mesmo estando num turno, editando.
- **Cenários concretos:**
  - **(a)** O Claude Code mata o `collie work wait` em primeiro plano pelo timeout do Bash (120 s por padrão, abaixo dos 600 s do wait). Também vale para Ctrl-C. O wait continua estacionado no daemon por até 10 min, e o Shepherd volta a ter um turno ativo.
  - **(b)** O Shepherd roda `collie work wait` com `run_in_background` (ou um Monitor) e segue trabalhando. Aqui o selo está `working` e o daemon só vê o wait.
- **Quanto pesa:** pouco, porque o diff rastreado contra `merged` continua barrando o reset (a edição já gravada aparece no diff). Sobram duas perdas possíveis:
  - a edição que cai entre o `git diff` e o `reset --hard` (ms, a mesma janela TOCTOU já declarada);
  - um `Write` do agente baseado no conteúdo que ele leu antes do reset, que reintroduz silenciosamente o merge desfeito naquele arquivo.

  Mesmo assim, o caso "starter editando continua contando" da spec (`tasks/m3c-2`, item 1) não vale nesses dois fluxos, e o `ponytail` de `:399-400` só cobre o (b).
- **Como confirmei:** leitura de `UnixSocket.process`/`halt` (o read source fica suspenso durante o handler, e não há `onCancel` nem detecção de EOF), do `CLI.timeout` (`Sources/collie/CLI.swift:16`, 600 s + 5 s) e do `defer` do `work.wait`. Não executei.
- **Correção sugerida (barata):** guardar o `peer` pid junto com o wait (`handle(_:peer:)` já o recebe) e, em `loopStarterWaits`, exigir `kill(pid, 0) == 0`. A alternativa é manter o read source armado durante o handler para ver HUP e cancelar a task. Qualquer uma resolve o (a). Para o (b), uma regra simples: o selo `working` posterior ao início do wait volta a contar.

### 2. Corrigir antes do push (M3c.4, teste): `LoopNotifyTests` usa `sleep` e relógio de parede, e a asserção negativa pode passar sem provar
- **Onde:** `Tests/CollieDaemonKitTests/LoopNotifyTests.swift:11-16` (`notices`: `ContinuousClock.now + 5 s`, `Task.sleep(20 ms)` em laço, mais `Task.sleep(200 ms)` de folga). É usado em `endSkipsTheDoneNoticeButNotTheDeferredOneNorTheEnd` (`:44-55`).
- **O que está errado:** a regra da onda (`onda3c.md`: "nenhum `sleep` novo") foi quebrada. Pior: com `--notify end`, a prova de que o aviso de tarefa feita **não** sai é `ended.count == 1` depois de 200 ms. Se a supressão regredir, o aviso extra é disparado num `Task` solto (`WorkLoop.swift:538-539`) e, sob carga, pode chegar depois da folga: o teste passa verde sem provar nada. No caso `task`, o laço espera até chegarem 2 avisos, e esse não tem o problema.
- **Correção sugerida:** testar a decisão sem relógio. Uma saída é contar no host falso as chamadas a `taskEnded` de forma síncrona. Outra é extrair `reportEnd` para devolver a linha (ou nil) antes do `Task`, e afirmar que é nil para a feita e não-nil para a adiada.

### 3. Corrigir antes do push (cobertura, M3c.2): nenhum teste junta o host real e um Shepherd preso em `work wait` durante uma integração
- **Onde:** `Tests/CollieDaemonKitTests/LaneIntegratorWaitTests.swift`.
  - `theDaemonKnowsWhatTheStarterIsServing` (`:111-145`) prova a contagem com o daemon real e um `work.wait` estacionado.
  - Os testes do integrador e do laço (`:149-250`) usam `anyoneWorking` falso, a constante `starter(open:waits:)` em `LoopFakeHost`/`WaitHost`.
- **O que falta:** a costura real `RouterLoopHost.anyoneWorking` → `loopAnyoneWorking` → `loopOthersWorking(starter:)` → `targetBusy` com o selo **`working`** do starter. No teste do daemon, o Shepherd é um `shell` em `/tmp`: o selo não é `working` e o `cwd` nem cai na worktree. Também não está provado que o `work` do `RouterLoopHost` é o trabalho ativo do starter que o `work.wait` usa como chave. Resposta à pergunta da brief: o teste "preso em `work wait` durante a integração inteira" existe só em duas metades. Nenhuma das duas prova o cenário real de ponta a ponta.
- **Sugestão:** um teste com `withDaemon` que estaciona o `work.wait` do starter, força o selo `working` (`hub`) e chama `RouterLoopHost(...).anyoneWorking()`, esperando `nil`. Depois, o mesmo teste com um segundo pedido aberto, esperando o nome do Shepherd.

### 4. Nit (desenho): o lixo não rastreado do portão agora fica para sempre na árvore do dono
- **Onde:** `Sources/CollieDaemonKit/Work/LaneIntegrator.swift:140-145` (`settle` sem `clean`). O teste foi mudado em `Tests/CollieDaemonKitTests/LaneIntegrationTests.swift:122-131` (`status() == ""` virou `"?? junk.txt"`).
- **O que acontece:** a spec se contradiz. O item 2 diz que o `restore` não faz `clean`. O item 3 pede o "mesmo desfecho do desenho original (volta limpo…)". A implementação seguiu o item 2, coerente com o achado 3 da 3b. Já o teste do item 3, "edita `f.txt`", reescreve o arquivo com o **mesmo conteúdo** (`cat f.txt > f.new; mv …`), então só prova o caso trivial. Um formatter de verdade num portão quebrado continua deixando o merge no branch, o que está dentro da regra da spec.
- **Efeito colateral:** se uma faixa posterior **adicionar** um caminho que o portão deixou não rastreado, o `git merge` recusa ("untracked working tree files would be overwritten"). Isso cai no ramo de conflito (`:89-97`) e é refeito até as tentativas acabarem e a tarefa ser adiada. Não perde nada, mas gasta tentativas sem diagnóstico.
- **Sugestão:** na nota de recusa de merge, citar o arquivo não rastreado no caminho. Ou documentar que o portão deve escrever em pasta ignorada.

### 5. Nit (segurança, só disponibilidade): qualquer processo com acesso ao socket pode fazer o starter "trabalhar"
- **Onde:** `Sources/CollieDaemonKit/CommandRouter.swift:383-386`. `requestBegan` conta pelo `terminalId` **declarado**, antes de `principal` verificar o token.
- **Cenário:** outro terminal manda pedidos inválidos com o id do starter enquanto o portão termina. O starter passa a contar como trabalhando, o merge quebrado fica no branch (`leftDirty`) e o laço para com `othersWorking`.
- **Por que é só nit:** forjar o contrário (fazer parecer que espera) exige o token, porque o `ownWaitBegan` só roda com `caller?.id == t.id` do `principal` autenticado. Conferi em `PaddockCommands.swift:10-19`. O desfecho é o mesmo de antes da 3c (sempre conservador). Isso responde à pergunta da brief: não dá para forjar o reset.

### 6. Nit (M3c.3, `905ca16`): a nota de recusa chama de "marcada" uma faixa que pode não ter marca
- **Onde:** `Sources/CollieDaemonKit/Work/LaneWorktree.swift:269` (a recusa vem **antes** de `isMarked`) e `Sources/CollieDaemonKit/WorkLoopCommands.swift:283` ("faixa marcada não removida…").
- **O que o `905ca16` faz:** antes dele, por um symlink X→Y, o `adminDir` resolvia `realPath(X/.git)` e lia a marca de **Y**. A faixa era então classificada como poupada ou como removível, e o `remove` recusava em seguida. Agora a pasta que não é dela é recusada sem ler marca nenhuma. Não é mais restritivo que a spec (item 2: "não é removida e vira nota de aviso"). É a forma correta de cumprir a spec.
- **O nit:** uma worktree do próprio dono num branch `collie/lane/*` fora da pasta de paddocks (sem marca) também cai em `refused`, e a nota diz "marcada". Trocar por "faixa não removida (a pasta não é a da faixa…)".

### 7. Nits menores
- **`docs/referencia.md` não cita `--notify`.** Só o `Commands.swift:400`, o `LoopCommand.body` e a orientação falam do flag. A spec do M3c.4 pede MCP e CLI coerentes, e a referência ficou de fora.
- **Conflito com outro terminal ocupado ainda para o laço.** Em `LaneIntegrator.swift:92-94`, depois do `merge --abort` a árvore já está em `before`, mas um `who` de outro terminal marca `disturbed`. A parte do starter do achado 2 da 3b foi corrigida. A dos outros terminais continua, e só acontece se alguém começar a trabalhar durante o merge, porque `othersWorking` é checado antes.
- **Testes do M3c.3 sem `.timeLimit`.** `LaneHardeningTests` é `@Suite(.serialized)` sem `.timeLimit`. `aChildThatOutlivesTheLeaderDiesOnCancel` gira em `while … { await Task.yield() }` (`:238`, `:244`), sem limite: se o líder não escrever o arquivo, o teste gira para sempre a 100% de CPU. Ele também mede `ContinuousClock` (< 60 s contra o timeout de 120 s). É uma margem grossa e aceitável, mas é relógio de parede. Também não confere que o `tail` morreu: se o teste falhar, o processo vaza.
- **Esperas ainda não canceláveis.** `LaneIntegrator.untilWaiting` (`Sources/CollieDaemonKit/Work/LaneIntegrator.swift:46-49`, usado em `LaneIntegrationTests.swift:196`), `LoopCancelTests.swift:27,31` e `LoopCancelWaitTests.swift:23` são continuations sem cancelamento. Estão fora do escopo nomeado do M3c.1, que cita só `Arrivals`/`Once`, mas são o mesmo padrão de travamento. Vale a regra de lint sugerida na 3b.
- **`LaneGitQueue` é por processo** (`LaneWorktree.swift:249-263`). Os `add` do `PaddockManager` e um segundo daemon (dev e instalado) no mesmo repositório continuam concorrendo. O `ponytail` declara o primeiro caso. A repetição do `commondir` cobre os dois.
- **Teste novo do M3c.1 não passa pelo `.timeLimit`.** `aLaneThatNeverComesEndsWhenTheRunIsCancelled` (`LoopParallelTests.swift:360-371`) cancela um `Task {}` solto à mão. Prova que o run cancelado termina, mas não o caminho do `.timeLimit`. A peça que faltava, o `Arrivals` cancelável, está coberta à parte por `aCancellableWaitReturnsOnCancel`.

---

## Áreas examinadas sem achado (e como)

- **M3c.2, vazamento do contador:** `requestBegan`/`requestEnded` estão num `defer` de `handle`, com o mesmo id no começo e no fim. Um terminal removido no meio do pedido não deixa sobra. `ownWaitBegan`/`Ended` também estão em `defer`, e um erro lançado depois (por exemplo `--since` inválido) devolve a contagem. Os dicionários são limpos quando chegam a zero, e o teste do daemon real confere `nil` no fim. Não há vazamento permanente, só a retenção do achado 1.
- **M3c.2, o reset:** `settle` só faz `reset --hard` com `who == nil` **e** `git diff --name-only <at> --` vazio (`at` = `merged` depois do portão e `before` no conflito). Um diff que o git não consegue dar vira `["?"]`, o que bloqueia. A edição rastreada do dono, um arquivo adicionado ao índice e um commit do dono durante o portão aparecem no diff ou viram "gate moved HEAD" e depois diff, e nada é resetado. O que o `reset --hard before` apaga é só o que o merge trouxe (rastreado) e o que o integrador deixou. Não rastreados nunca são tocados: não há mais nenhum `clean` (`rig.destructive()` confere nos testes). A regra da M3b.2 não regride (`theOwnersEditDuringTheGateStays`). A cobertura original de limpeza foi restaurada para os **rastreados** (`head == base`, `status --untracked-files=no == ""`, `a.txt` sumiu). A dos não rastreados mudou de propósito (achado 4).
- **M3c.2, portão que passou:** `kept` só fica não vazio quando um rastreado mudou (`LaneIntegrator.swift:122-125`). Não rastreados novos viram `left` e saem em `leftNote`, com `eventDetail`, no máximo 10 nomes e "e mais N" (`WorkLoopLanes.swift:234-235`, `:287-291`).
- **M3c.2, dois terminais do mesmo Shepherd:** só o id do starter sai da conta. Qualquer outro terminal do cercado com `cwd` na worktree continua contando (`loopReaching`, `WorkLoopCommands.swift:423-434`).
- **M3c.1, fila:** `serial` libera nos dois ramos (retorno e `throw`). `createLocked` chama `removeLocked`, não o `remove`, e não tenta pegar o lock de novo. `cut` libera o lock antes do `dropLane`, e `sweep` não segura lock em volta do `remove`. Não achei deadlock. `acquire` não é cancelável de propósito (o `dropLane` de uma task cancelada), e as chamadas são curtas. A entrega é FIFO, com `busy` mantido na passagem do lock. A chave é `realPath(p.repoRoot)`, a mesma para todos os cercados do repositório. A repetição única só acontece com "failed to read" + "commondir". Antes dela, `removeLocked` limpa o que o `add` falho deixou, e caminho e branch tinham sido conferidos como ausentes sob o lock (`LaneWorktree.swift:148-161`). `fourCreatesAtOnceAreAllBornTwentyTimesOver` prova a serialização com `maxInFlight == 1`, que é a prova forte, porque sem carga a corrida quase nunca aparece. O `Arrivals` novo (`LaneCreateSerialTests.swift:8-23`) cobre o cancelamento antes e depois de guardar a continuation: o corpo roda no actor e o `drop` volta ao actor.
- **M3c.3, perfil:**
  - `deny file-write*` em `lit(project)` e `lit(worktree)` vem depois de todos os `allow` (`SandboxProfile.swift:263`), e no SBPL vale a última regra. Os caminhos já são `real(...)` (`:86-87`). O conteúdo continua aberto por `sub(...)`. O git da faixa (`add`, `commit`, `status`, que reescreve `index` na pasta de admin) não escreve nas pastas em si. O teste de commit real confere que todo arquivo alterado é permitido pelo `ProfileRules`.
  - O `gc --auto` não muda com esta regra: segue o nit da 3b (`packed-refs.lock` fechado).
  - O pai das pastas (`<common>/worktrees`, a pasta de paddocks) não tem `allow` no perfil da faixa.
  - **Não provado contra o Seatbelt real.** Tudo passa pelo modelo `ProfileRules`.
- **M3c.3, symlink:** `ownsPath` exige `realPath(path) == realPath(pai)/nome`, então um link em `/var` acima da pasta continua aceito. `remove` recusa quando `lexists && !ownsPath`, **antes** de listar worktrees. O `git worktree remove --force` só recebe `wt.path` que passou por `ownsPath`. O perfil novo impede a faixa de trocar a própria pasta por um link, e o `remove` recusa se isso acontecer por outro caminho.
- **M3c.3, SIGKILL pelo pgid:** o pgid é guardado no spawn e zerado só depois de os drains terminarem ou serem abandonados (`BoundedProcess.swift:111`, `:163`). Enquanto existir um membro, o POSIX não reusa aquele id como pid, então o `kill(-pgid)` não alcança outro grupo. Sobra a janela entre a saída do último membro e a linha 163, que só importaria se um pid reusado fizesse `setpgid` próprio. Está declarada no `ponytail` e é desprezível. O caminho de timeout segue igual.
- **M3c.3, marca e nota:** `isMarked` exige `work8` igual **e** o UUID inteiro aceito pelo predicado: `{ $0 == id }` no fim do laço e `{ !known.contains($0) }` na partida (`theMarkIsTheWholeWorkId`). Faixas sem marca continuam poupadas. A nota sai uma vez por daemon, por repositório e branch (`notedLanes`, estático).
- **M3c.4:** todo aviso por tarefa passa por `reportEnd` (6 chamadas: `WorkLoop.swift:485,502` e `WorkLoopLanes.swift:185,208,304,328`). Só `state == .done` com `notify == .end` é suprimido. Adiada, parada (qualquer `Stop.Code`, pelo `loopEnded`), fim e início não mudam. O estado é tolerante: `try? decodeIfPresent`, e um valor malformado vira `nil`, que equivale a `task`. Valor inválido é recusado (`WorkLoopCommands.swift:81-85`). O que entra no texto injetado são **constantes** ("avisos: só no fim", "work run --notify end saves turns."), nunca o valor do usuário, então não há injeção. A orientação testa o limite de 1500 em todas as formas e agentes (`LoopNotifyTests:111-121`). O `0719153` só ajusta a expectativa da linha do Codex para a forma com a frase de `--notify`, porque o Codex tem espaço sobrando. Nenhuma expectativa foi afrouxada.
- **Testes enfraquecidos ou removidos (`git diff 7402095..0719153 -- Tests/`):**
  - `LaneIntegrationTests`: `status() == ""` virou rastreados limpos + `?? junk.txt`, e `ok.kept == [f, junk]` virou dois casos (não rastreado sozinho e rastreado sozinho).
  - `LaneIntegratorRaceTests`: o caso "não rastreado novo prende a árvore" foi invertido, agora com a asserção de que não há `clean`.
  - As duas mudanças são de propósito e seguem a spec.
  - `Arrivals` saiu dos três arquivos para o compartilhado cancelável.
  - `CollieOrientationTests`: a linha do Codex mudou (ver acima).
  - Nenhuma asserção de segurança foi removida. Os `sleep`/relógios novos estão nos achados 2 e 7.

## Melhorias de fluxo e desenho (fora dos achados)

1. **Ligar o "só esperando" ao cliente vivo** (achado 1), não ao pedido aberto. A regra fica certa para Ctrl-C, timeout do Bash e wait em segundo plano.
2. **Rodar o portão fora da árvore do dono** (rebase da faixa, portão na faixa e fast-forward). Continua sendo a saída que encerra de uma vez os achados 1, 4 e a janela TOCTOU. O `ponytail` em `LaneIntegrator.swift:121` aponta para isso.
3. **Uma fila única de operações de worktree no daemon,** para faixas e paddocks, em vez da `LaneGitQueue` só das faixas.
4. **`--notify end` como padrão para `--parallel > 1`,** onde os avisos por tarefa custam mais turnos. Ou a orientação sugerir isso explicitamente.
5. **Lint de teste** contra `withCheckedContinuation` sem `withTaskCancellationHandler` e contra `Task.sleep` nas suítes do laço. Pegaria os achados 2 e 7.

## Higiene desta revisão

- Escrito só este relatório. Não mexi em nada rastreado e não commitei.
- Sem build, sem testes, sem `kill`, sem rede.
- Cópias das fontes no commit ficaram em `/private/tmp/claude-501/-Users-ysraelmoreno-Documents-codes-my-orchestrator-memory--collie-paddocks-collie/06615830-5594-4baf-b2d3-b669e1807ebb/scratchpad/src/`.
