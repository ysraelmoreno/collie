# RESULTS S9 — parar durante o land (`specs/s9-square.md`)

BASE0: b92d5c83d7e9189a9966ac9eca9cbcae62932479 ("e2e: lote 4, autoLandPerDay 20 and CI sleep 40 (S9)"; `git merge main --no-edit`: fast-forward 54376c8..b92d5c8). Cercado limpo.
Remoto: só `b8e3f6c` antes e depois (nunca ganhou commit).

Resumo: foram 3 execuções. A 1ª parou na revisão antes do land. Na 2ª, **meu gatilho falhou e o S9 integrou** (pelo laço, merge local, sem push). A 3ª (S9b, repetição) parou de verdade durante o CI do land.

## Execução 1 — work a13e8752 "S9 stop", run 1 (12:04:26–12:06:19 UTC)
```
collie work start "S9 stop"
collie work task add "S9 square" --spec specs/s9-square.md --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def square" calc.py'
collie work run --max 3 --review --auto-land
```
- t1: prompt não entregue (promptRetry 1/2) → agente de novo → commitSeen 4be33f9 · check 0 · gate 0
- 12:06:02 reviewerMute "revisor correcao sem resposta (causa: prompt não entregue)" → reviewRetried → mudo de novo → verdict passou
- 12:06:19 stopped: `landReviewVeto` "S9 square: parecer: sem parecer (personas: correcao; 0 achados)"
- Notes: "auto-land: revisão sem aprovação limpa …; nada integrado" · "descartei do cercado os commits da tentativa (b92d5c83d7e9..4be33f9ba43f) … O cercado voltou a b92d5c83d7e9. Patch: …/discarded/2026-11-25-090616-4be33f9ba43f.patch" · tarefa reaberta.
- Não chegou ao CI do land. Não houve `work stop`.

## Execução 2 — mesmo work, run 2 (12:06:41–12:09:33 UTC) — **INTEGROU**
- `collie work run --max 3 --review --auto-land` de novo.
- t1: prompt não entregue 2× (promptRetry 2/2) → check exit 1 "no new commit" → discarded sem alterações
- t2: commitSeen 058adc0 · check 0 · gate 0 · 12:08:51 verdict passou (correcao approve)
- **12:09:33 landed b92d5c83d7e9 -> aeb442bff62d** · `stopReason` `{"code":"landed","detail":"b92d5c83d7e9 -> aeb442bff62d"}`
- **Falha minha:** o watcher esperava um evento de CI do land (tipo com "ci") para disparar `collie work stop`. O diário do laço **não tem evento de CI do land**: entre `verdict passou` (12:08:51) e `landed` (12:09:33) não há evento nenhum (esses ~42 s são o `sleep 40` do CI). O stop nunca foi enviado. O land foi feito pelo laço (auto-land, sem push), não à mão.

## Execução 3 — work 7f78321f "S9b stop" (repetição) (12:10:11–12:11:37 UTC)
Como `square` já estava na base, a tarefa foi trocada por `cube` (mesma forma; sem arquivo de spec, descrição no título):
```
collie work start "S9b stop"
collie work task add "S9b cube: em calc.py acrescente def cube(a): return a * a * a e um teste test_cube em tests/test_calc.py (cube(2) == 8). Rode bash scripts/gate.sh. UM commit." \
  --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def cube" calc.py'
collie work run --max 3 --review --auto-land
```
Gatilho: 3 s depois de `verdict passou` (já dentro do CI do land com `sleep 40`).
```
12:10:12 agentSummoned t1 · 12:10:47 commitSeen f37175f · check 0 · gate 0
12:10:55 verdict passou (correcao approve, "sem spec no commit base")
12:10:59.338 STOP -> collie work stop      -> {"state":"stopped"} rc 0 (resposta em 0,3 s)
12:10:59 stopRequested
12:11:37 stopped "pedido pelo dono (work stop)"
```
- `stopReason`: `{"code":"requested"}` (parada do dono, não `landed`).
- **Tempo para parar:** 38 s entre o pedido (12:10:59) e o `stopped` (12:11:37).
- **O CI do land NÃO foi interrompido:** o CI começou por volta de 12:10:56 e o `sleep 40` acaba por volta de 12:11:36, logo antes do `stopped`. O laço esperou o CI terminar e então não fez o merge.
- Notes: só "parecer … sem veto" e "[loop] laço parado: pedido pelo dono (work stop)". **Nenhuma nota sobre o commit da tentativa.**
- Tarefa 330fcd8b ficou `done`, mesmo sem integrar.
- **O commit f37175f NÃO foi descartado:** o cercado ficou em `f37175f feat(calc): add cube with test_cube` em cima de aeb442b. A árvore está limpa, mas o commit continua lá (é a armadilha 15053c3a: ele entra no próximo land). Não mexi nele (só o dono pode autorizar reset no cercado).
- Não repeti com `--now`: o `work stop` normal já parou antes do land.

## Base / remoto (final)
```
$ git -C repo log --oneline -5
aeb442b Land paddock (auto-land): S9 stop
058adc0 feat(calc): add square with test_square
b92d5c8 e2e: lote 4, autoLandPerDay 20 and CI sleep 40 (S9)
54376c8 Land paddock (auto-land): S6a mod
77ab271 feat(calc): add mod with test_mod

$ git -C origin.git log --oneline
b8e3f6c e2e fixture: calc with unittest, gate and factory profile
```
Cercado: `f37175f` (cube, sem land) em cima de `aeb442b`.

## ESPERADO x OBTIDO
ESPERADO: nada integrado depois do pedido (base em BASE0), stopReason de parada do dono, commits descartados ou notados, cercado limpo.
OBTIDO (S9b, a parada de verdade): nada integrado depois do pedido ✅ (base ficou em aeb442b, a BASE0 do S9b) · `requested` ✅ · o CI do land rodou até o fim (não foi interrompido) e a parada levou 38 s · commit f37175f **não descartado e não notado** ❌ · tarefa marcada `done` sem integrar ❌.
Desvio: a execução 2 integrou `b92d5c8 -> aeb442b` porque meu gatilho de stop nunca disparou (não existe evento de CI do land no diário), então a base não está mais na BASE0 original do S9.

## Achados para o Collie
1. Falta um evento no diário para o CI/portão do land (ex.: `landCiStarted`/`landCiFinished`). Hoje só se infere pelo silêncio depois do `verdict`.
2. `work stop` durante o land espera o CI acabar (38 s), em vez de interromper.
3. Parada no land deixa o commit da tentativa no cercado, sem nota e com a tarefa `done` (o caminho `landDailyCap`/`landReviewVeto` descarta e reabre; o `requested` não).
