# Revisão das Ondas 7 e 8 (M7.1 a M7.3, M8.1 a M8.3), `94fa10a..39cc3ad`

**Bloqueia a instalação? Não.** Nenhum caminho novo apaga arquivo do dono nem deixa dois laços rodarem, e o isolamento do histórico entre cercados (A1) está fechado em `list`/`get`/`import`/`export`. Antes do push, corrigir três pontos: (B1) sem laço rodando, o histórico fica inalcançável no app; (B2) a falha de "Abrir no canvas" ficou muda; (B3) o `discard` do laço serial ainda lê os nomes do dono com `trim` (resíduo de A5).

Método: li tudo **pelo commit** (`git show 39cc3ad:…`, `git diff 94fa10a..39cc3ad`). Rodei `scripts/ci/lint.sh` (ok) e `scripts/ci/check-architecture.sh` (ok). Não rodei build nem testes.

---

## Achados (do mais grave ao menos)

### B1. Sem laço rodando, o histórico não abre em lugar nenhum do app (corrigir antes do push; decisão do dono)
`Sources/CollieApp/ContextPanel.swift:45` (`if loops.visible, let card { loopsSection(…) }`), `:69`, `:72`.
- **O que está errado.** A M8.2 tirou o HISTÓRICO do Trilho, e o modal "Laços" passou a ser a única tela dele. Só que o modal abre por dois caminhos, "Ver tudo" e o card, e os dois só existem enquanto um laço do cercado roda (`LoopSection.visible`). Fora isso não há outra entrada: grep de `onOpenLoops`/`.loops(` acha só `ContextPanel.openLoops` e a ligação em `CollieApp.swift:354`. O ramo de `LoopsModal.initialTab` que abre em Histórico quando nada roda só acontece numa corrida (o laço acaba entre o clique e o `init`). O link "mais antigos no Work" (`ctx.openWork`) saiu junto com a seção.
- **Cenário.** O laço termina. O dono quer ver o resumo, o motivo de parada ou as tarefas adiadas do trabalho que acabou de fechar, e no Trilho não há nem card nem botão.
- **Como confirmei.** Leitura de `ContextPanel.body` e grep pelo commit das chamadas de `onOpenLoops`.
- **Correção sugerida.** Mostrar o cabeçalho `LAÇOS` com "Ver tudo" (sem card) sempre que o cercado tiver histórico (`!workFeed.history.isEmpty`), e o card só com laço rodando. Outra opção: uma entrada na paleta ou no menu ("Laços…"). A spec M8.2 pediu exatamente o que foi feito, então a escolha é do dono.

### B2. A falha de "Abrir no canvas" não aparece mais (corrigir antes do push)
`Sources/CollieApp/LoopsSheet.swift:245` e `Sources/CollieApp/CollieApp.swift:354` (`historyNotice:`).
- **O que está errado.** `HistoryOpener.show` grava a falha em `message` ("Não foi possível abrir o histórico"). Quem mostrava esse texto era a `historySection` (via `ctx.historyNotice()`), que a M8.2 removeu. Hoje `historyNotice` não é lido em lugar nenhum (grep pelo commit: só a definição em `Shell.swift:36` e a ligação). O botão fecha o modal (`dismiss()`) antes de chamar o hook, então uma falha de `artifact.add` ou de `panel.open` não deixa nenhum sinal. A M7.1, item 4, pede "texto fixo em falha".
- **Cenário.** O daemon recusa o `artifact.add` (por exemplo, "the artifact was removed meanwhile" em `replaceAgentPage`). O modal fecha e nada abre.
- **Correção sugerida.** Mostrar `ctx.historyNotice()` no modal e só fechá-lo depois que a Prévia abrir, ou mostrar a mensagem num toast.

### B3. `discard` do laço serial: os nomes que o dono deixou são lidos com `trim`, e um arquivo do dono pode ir junto com o descarte (corrigir antes do push, barato; resíduo de A5, pré-existente)
`Sources/CollieDaemonKit/Work/WorkLoop.swift:787-789` (`untracked` usa `out`, que faz `trimmingCharacters(.whitespacesAndNewlines)` em `:810`), usado em `:230` (`keep`) e em `:796`.
- **O que está errado.** A M7.2 corrigiu o `reset` (`--literal-pathspecs`) e a guarda do portão (`diff -z`, lida sem `trim`). Mas a lista `keep`, ou seja os arquivos não rastreados do dono antes da tentativa, ainda vem de `ls-files -z` passado por `out()`, que corta espaços e quebras de linha das **pontas da saída inteira**. Com isso, o primeiro nome (em ordem de bytes) perde o espaço ou a quebra de linha do começo, e o último perde o do fim. No `discard`, o `add -A` põe no stage o arquivo real, `" notas.txt"`. O `reset -- "notas.txt"`, agora literal, não acha esse nome, e o arquivo continua no stage. Em seguida o `reset --hard before` (`:804`) apaga o arquivo da árvore. O arquivo só sobrevive dentro do `.patch`, e só se o patch couber em 1 MiB.
- **Cenário.** O dono tem um arquivo não rastreado chamado `" rascunho.md"` (com espaço no início, o que o põe primeiro na ordem). Uma tentativa falha e o `discard` roda: o arquivo some da worktree.
- **Como confirmei.** Leitura de `untracked`, `out`, `discard` e `settle`. No `settle` o efeito é seguro, porque `loose` e `made` vêm da mesma função cortada e o `clean` só erra para o lado de não apagar. O teste `discardKeepsTheOwnersGlobNamedFileLiterally` cobre o glob, não as pontas.
- **Correção sugerida.** Em `untracked`, ler o `stdout` cru: `host.git([...]).stdout.split(separator: "\0")`, sem `out()`, como já é feito em `:757`. Um teste com `" a.txt"` no `keep`.

### B4. O histórico esconde trabalho real que tem só notas (nit; a spec pediu assim)
`Sources/CollieCore/WorkArchive.swift:89` (`listed`).
- **O que está errado.** `listed = !tasks.isEmpty || stopReason != nil || !timeline.isEmpty || !loopSummary.isEmpty`. As notas não entram nessa conta. Um `work start "investigar X"` que acumulou notas e foi fechado sem tarefas some da lista. Nada é apagado: o resumo continua no disco e `--id` ainda o lê, então o filtro é só na leitura (`WorkCommands.swift:419`). Tarefas `abandoned` (`work task drop`) continuam no array, então trabalho com tarefas só abandonadas **aparece**.
- **Sobre a causa.** Foi corrigida **na origem**, e o commit `cae9812` diz isso: `workHook` não abre trabalho implícito para um terminal citado por um job `.loop` rodando (`WorkCommands.swift:23`). Com isso, o trabalho fantasma de tentativa não nasce mais, e o filtro só serve para os antigos. Dá para incluir `|| !notes.isEmpty` sem trazer os fantasmas de volta.
- **Relacionado.** Os resumos de trabalhos vazios continuam sendo gravados e contam no `keep = 200` de `WorkArchiveFiles`, então os antigos empurram resumos reais para o prune mais cedo. Hoje a pressão é pequena, porque a origem está corrigida.

### B5. Um trabalho fechado com o laço rodando segura o cercado, e `work stop` não alcança esse laço (nit)
`Sources/CollieDaemonKit/WorkLoopCommands.swift:50-53` e `:246`.
- **Trava para sempre?** Não. Os casos que conferi:
  - **Reinício do daemon:** `stopLoopsLeftRunning` já varre `includeClosed: true` e grava `stopped`/`daemonRestart`.
  - **Fim normal:** o engine grava o estado final.
  - **Engine que acaba sem conseguir gravar** (`try? store.update` falha no fim de `run`): o `running` gravado fica e trava o cercado até o próximo reinício. Antes, isso já acontecia com trabalho aberto.
- **Dois laços?** Não. Além da trava gravada, existe a reserva em memória `loopPaddocks`, que vale até `loopEnded`. Essa reserva **já** barrava o cenário de A2 enquanto o engine vivia. A mudança da M7.2 é redundante para laço vivo, e o que de fato protege a quarentena é a marca nova. Vale anotar isso na história de A2.
- **O que está errado.** A mensagem diz "collie work stop ends it", mas `workStop` busca `work.active(terminal:)`, que exclui trabalhos fechados. O Pastor não consegue parar um laço cujo trabalho ele já fechou, e o laço só para no próximo despertar (até um turno, `--timeout`, de até 4 h).
- **Correção sugerida.** No `workStop`, aceitar também o trabalho fechado do terminal que tem `workLoops[id]` vivo, ou trocar a mensagem por uma que não prometa o que não acontece.

### B6. A2/M7.1: histórico de antes da M7.1 (`paddockId nil`) fica visível para terminais do Pasto; ids vazam por `artifact.folders` (nit)
`Sources/CollieDaemonKit/ArtifactCommands.swift:181-184`.
- `hidden` compara `a.paddockId != caller.paddockId`. Uma página `history-*` gravada pela Onda 6 tem `paddockId nil`, então qualquer terminal sem cercado a lista e a lê até o dono abri-la de novo, quando `replaceAgentPage` grava o cercado certo. Só afeta quem rodou o build da Onda 6 e clicou no histórico.
- `artifact.folders` devolve os ids da pasta `Histórico` a qualquer terminal (já admitido no `ponytail:`). Com o id, um agente de outro cercado ainda consegue `artifact.move` (decisão antiga: qualquer agente move qualquer artifact) e `panel open artifact:<id>`. O conteúdo não vaza: `get`, `import` e `export` passam por `seen()`, e a raiz de dados do Collie fica fechada para leitura no sandbox (`SandboxProfile.swift:237`).
- **Correção sugerida.** Para `history-*` com `paddockId nil`, esconder de todo não-admin (ou derivar o cercado do resumo). Filtrar `items` de `history-*` em `artifact.folders`.

### B7. Modal: `ForEach(…, id: \.self)` com textos que podem se repetir (nit)
`Sources/CollieApp/LoopsSheet.swift:250`, `:274`, `:291`.
- Em `d.notes` (as 20 notas mais recentes) a mesma nota de `[loop]` ou `[collie]` pode aparecer duas vezes, e em `t.why` `failure` pode ser igual a `evidenceNote`. Ids duplicados no `ForEach` dão comportamento indefinido no SwiftUI: linha some ou se repete, e o console avisa. Usar `Array(enumerated())` com `id: \.offset`.

### B8. Modal: dois cliques seguidos no histórico podem mostrar o detalhe errado (nit)
`Sources/CollieApp/LoopsSheet.swift:231-235`.
- `open` não guarda qual id foi pedido por último, então quem responder por último vence: com cliques em A e depois em B, se A responder depois, o detalhe mostrado é o de A. Correção: `guard loading == id` antes de atribuir `detail`.

### B9. `isLoopAttempt` lê todos os trabalhos (abertos e fechados) a cada hook de um terminal sem trabalho (nit, desempenho)
`Sources/CollieDaemonKit/WorkCommands.swift:23`.
- Toda tentativa de laço é um terminal sem trabalho ativo, então todo hook que abriria trabalho (job, task) faz um `work.list(includeClosed: true)`. Cabe no limite atual. Se pesar, consultar primeiro `workLoops` em memória (os laços vivos) e só ler do disco quando não houver nada ali. Um `jobStarted` tardio, depois que o job `.loop` foi marcado como encerrado, ainda abre trabalho implícito. É raro, e o filtro do histórico o esconde.

---

## Áreas examinadas sem achado

- **M7.2, literal (grep pelo commit de todo `git` em `LaneIntegrator.swift`, `WorkLoop.swift`, `WorkLoopLanes.swift`).**
  - Com nomes e literal: `status` (110), `hash-object --` (282), o `diff -z`/`ls-files -z` do integrador (sem mudança), `clean --` (782) e `reset --` (796).
  - Sem nomes: `merge`, `reset --hard <sha>`, `checkout -f <branch|sha>`, `rev-parse`, `log`, `diff --shortstat`/`--binary` entre shas, `add -A`.
  - `show`/`cat-file` usam `rev:path`, que é a sintaxe de revisão, não pathspec, e não expande glob.
  - A guarda do portão agora lê `-z` sem `trim` (757-760).
  - Resíduo: B3.
- **M7.2, quarentena.**
  - `clearQuarantine` só remove caixas cuja marca `<n>.work` é igual ao id do próprio trabalho. Caixa sem marca, ou com marca de outro, fica (teste `aLoopNeverEmptiesAnotherLoopsQuarantine`).
  - A raiz só é removida vazia.
  - Integrador sem `work` não apaga nada.
  - `removeItem` não segue symlink.
  - A marca fica no gitdir, que o sandbox fecha para escrita.
  - Uma marca órfã é sobrescrita pelo próximo `newQuarantine`.
  - Se a gravação da marca falha, a caixa fica sem marca e nunca é apagada (lado seguro).
- **M7.2, TOCTOU.** `inside` resolve o diretório pai, não o arquivo: um symlink deixado pelo portão continua sendo movido como link. A janela entre a checagem e o `rename` está admitida no `ponytail:`. O teste usa o probe de git logo depois do `hash-object`, que é o ponto exato da troca.
- **M7.1.**
  - A página fica no cercado do trabalho (`work.history { id }`) e na pasta `Histórico`.
  - `replaceAgentPage` faz temp + `rename` sobre `<id>/source.html` e apaga só as pastas `r[0-9]+` dentro da pasta do próprio artifact, achado por `continued(origin:)`. Nada do título vai para o caminho.
  - `history-` continua aceito só do admin: o teste confirma que um terminal com `--source history-…` é recusado.
  - Título `<script>`/`../`: escapado na página. No modal, `Text(verbatim:)`.
- **M8.1, tentativa.**
  - Linha `running`: `min(tries+1, max)`.
  - `done`/`deferred`: `tries`.
  - `open` nunca tentada: vazio. `accessibilityLabel` descarta o vazio.
  - Card e modal usam o mesmo `attempt`.
- **M8.1, histórico.** O filtro é na leitura. `--id` ainda lê um trabalho vazio. O fake (`FakeHistory`) usa `WorkArchive.listed`, a mesma regra do daemon. O teste de ponta a ponta roda num daemon real.
- **M7.3.**
  - O feed recarrega o histórico quando chega evento de um id que não está em `active` (`touched`). A captura `seen` vem antes do `ask`, então um evento durante a leitura cai na próxima volta.
  - `settled()` é uma continuation resolvida no `defer` do `drain`. `refresh` liga `busy` de forma síncrona, então um `settled()` logo depois de `workChanged` nunca volta cedo.
  - `aBurstIsOneReadInFlight`: sem a coalescência, cada `workChanged` abriria um `drain`, o `hold` prenderia vários e `maxInFlight > 1` e `statusCalls == 52 ≠ 3` falhariam. A prova não depende de relógio.
  - Os negativos ("outro cercado") ficam determinísticos, porque o evento ignorado não cria Task.
- **Sem `sleep`/relógio:** grep das linhas `+` de `git diff 94fa10a..39cc3ad -- Tests/` por `sleep`, `Date()`, `.now`, `ContinuousClock`, `asyncAfter` e `waitFor(` não acha nada novo. O `waitFor` de `refuseCard` vem de um helper antigo. O `TimelineView(.periodic 30 s)` do modal só redesenha o tempo decorrido e não chama o daemon. Os dados chegam pela observação do `WorkFeed`, sem polling.
- **M8.2/M8.3, UI.**
  - `sectionTitles` sem HISTÓRICO.
  - Card só com laço rodando.
  - `fraction` com `total > 0` (sem divisão por zero) e com clamp na barra.
  - Barra sem animação com Reduzir Movimento, e o `LoopStateIcon` igual.
  - Todo texto vindo do trabalho entra por `Text(verbatim:)`. Os `Text(String)` restantes são constantes do código, e `heading(String)` é verbatim. Nenhum `AttributedString(markdown:)`, `Link` nem `openURL` (grep).
  - `openInCanvas` é `@MainActor`.
  - Aba, seleção, carregamento e erro estão em `@State`, nada em disco.
  - Esc fecha (`.cancelAction`, e a sheet também).
  - Rótulos: card, "Ver tudo", linhas, histórico e cabeçalhos com `.isHeader`.
  - A Compacta e as Preferências não estão no `diff --stat`.
- **Testes (`git diff … -- Tests/`).**
  - `ContextPanelHistoryTests` perdeu `hookCallsWithTheRightId`, mas o hook agora é coberto por `openInCanvasCallsTheOldHookWithTheId`, e `HistorySection` continua testada.
  - Em `ContextPanelLoopsTests`, a tarefa rodando passou de `tries: 2` para `tries: 1`, mantendo "tentativa 2/3" (a semântica nova, não um enfraquecimento), e "tentativa 0/3" virou "".
  - `WorkArchiveTests` ganhou uma tarefa para o trabalho ser listado.
  - `GateCleanLiteralTests` passa o `work` para o integrador.
  - Nada foi removido sem substituto.

## Melhorias de fluxo ou de desenho (não são achados)

1. A trava "um laço por cercado" podia viver só em memória (`loopPaddocks` já é isso). A leitura gravada com `includeClosed` só acrescenta o risco do `running` órfão (B5).
2. A marca da quarentena podia ir para o nome da caixa (`<n>-<work>`), em vez de um arquivo irmão: uma escrita a menos e nenhuma caixa sem marca.
3. A nota de abertura de `work run` podia dizer que as caixas de quarentena **deste** trabalho (N arquivos) serão esvaziadas, e citar as caixas de outros trabalhos que ninguém mais vai esvaziar.
4. O detalhe do modal já mostra tudo o que a página mostra. "Abrir no canvas" podia virar "Exportar", e o artifact `history-*` deixaria de existir (somem B6 e o acúmulo).
