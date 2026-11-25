# C5c: `work run` não bloqueia no pré-check; auto-land que para descarta o commit da tentativa

Dois achados da A7 (2026-11-25).

## 1. O pré-check "check já passa" não pode bloquear o `work run`
`CommandRouter.alreadyGreen` (`Sources/CollieDaemonKit/WorkLoopCommands.swift` ~218, chamado ~167 antes de iniciar o laço) roda o check de cada tarefa aberta, em série, com o timeout padrão do laço (30 min) e SÍNCRONO dentro de `work run`. Com checks pesados (`swift test`, build frio) o `work run` leva minutos, o cliente desiste com "timed out waiting for daemon" e o cercado fica reservado ("a loop is already running") sem o dono saber o que acontece.
Corrija:
- O pré-check roda DENTRO do laço, como primeira fase ("verificando checks que já passam"), não no `work run`: `work run` volta na hora com `state: starting`; o diário grava `preCheckStarted/Finished`.
- Cada check do pré-check tem teto próprio (`preCheckTimeout`, padrão 120 s, injetável nos testes); estourar o teto conta como VERMELHO (não prova que já passa) e segue. Rodam até 4 em paralelo.
- Se alguma tarefa já passa: o laço termina SEM tentativa, com `stopReason` `checkAlreadyGreen` (finishes: false), a mesma mensagem de hoje (qual tarefa, `--green-ok`) na nota e no `work status`, e o `notify` ao dono.
- A reserva do cercado vale durante o pré-check; `work stop` o interrompe na hora (cancela os checks).
Testes (hosts falsos, relógio injetável): `work run` volta antes de o pré-check terminar; check lento estoura o teto e conta vermelho; check verde para o laço com `checkAlreadyGreen`; `--green-ok` pula; `work stop` durante o pré-check cancela.

## 2. Auto-land que para por base mudada não deixa commit solto
Hoje, quando o auto-land para por `landBaseMoved` (ou `landNotFactory`, `landDoctorRegressed`, `landReviewVeto`, `landCiRed`, `landGateRed`), os commits da tentativa ficam no ramo do cercado e entram no land seguinte de OUTRO trabalho (visto no S4→S5b: o `neg` do S4, que o dono mandou refazer, entrou no land do S5b).
Corrija: quando o laço com `--auto-land` termina com um `stopReason` de land que NÃO integrou (`landGateRed`, `landReviewVeto`, `landCiRed`, `landDirty`, `landConflict`, `landBaseMoved`, `landAcceptRed`, `landDailyCap`, `landDoctorRegressed`, `landTasksNotDone`, `landNothing`), o cercado volta ao commit em que o trabalho começou (o `baseHead`/HEAD no início do trabalho): `git reset --hard <commit-inicial>` NO cercado (nunca na base), e os commits descartados ficam guardados como patch em `work-loops/<trabalho>/discarded/` (fora da árvore do agente), citados na nota (hash e arquivos). A nota diz exatamente o que foi descartado e como recuperar (`git am`). Só se a árvore do cercado estiver limpa; senão não mexe e avisa o dono. Nunca no caminho `landed`.
Testes (git real em repositório temporário): `landBaseMoved` descarta o commit e o próximo land não o leva; o patch existe; árvore suja não é tocada; `landed` não descarta nada; a base nunca é alterada.

Check: `scripts/check-autoland-loop.sh c5c`. Commit ao final, só os arquivos da tarefa. Suítes novas: `PreCheckTests`, `LandDiscardTests` em `Tests/CollieDaemonKitTests`. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.

## 3. A reserva do cercado nunca vaza (achado de 2026-11-25, depois de escrever 1 e 2)
Um `work run` cujo cliente desistiu (timeout) durante o pré-check deixou `loopPaddocks` com o cercado reservado SEM laço: `work run` passou a responder "a loop is already running in paddock", `work stop` responde "no loop is running" e nada na CLI libera; só reiniciar o daemon. Garanta que toda saída de `work run` e do laço (erro, cancelamento do cliente, recusa, `stopped`) libera a reserva (`defer` que cobre também o cancelamento da `Task` do comando; o pré-check dentro do laço do item 1 já tira o trabalho longo do comando). Acrescente um reparo: `work stop` num cercado reservado sem laço em `workLoops` libera a reserva e responde `released` (teste: reserva sem laço + `work stop` libera; cancelamento no meio do pré-check libera).
