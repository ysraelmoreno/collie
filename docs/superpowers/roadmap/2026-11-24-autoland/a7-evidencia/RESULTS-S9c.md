# RESULTS S9c — parar durante o land (repetição, gatilho `landCiStarted`)

## Preparo
- Base (fixture, main): `sleep 40` reintroduzido no fim de `scripts/ci/run-tests.sh` → commit `1a4a61c e2e: S9c, reintroduce CI sleep 40`.
- Cercado: estava limpo e sem sobras (`git log <base>..HEAD` vazio); `git merge main --no-edit` → fast-forward f289b09..1a4a61c.
- BASE0: 1a4a61cf1bf2d4ac8ad3a8f2a3ec992f6cf83b46. Remoto: só `b8e3f6c`.

```
collie work start "S9c stop"                                  -> e84c0863-650e-4d66-b9ed-1316833a61a0
collie work task add "S9c negate: em calc.py acrescente def negate(a): return -a e um teste test_negate em tests/test_calc.py (negate(5) == -5). Rode bash scripts/gate.sh. UM commit." \
  --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def negate" calc.py'   -> 598c8f14
collie work run --max 3 --review --auto-land
```
Watcher: lê `collie work get` a cada 0,5 s; no 1º `landCiStarted` roda `collie work stop`; também monitora `pgrep -f scripts/ci/run-tests.sh`.

## Diário (UTC; coluna da esquerda = relógio do watcher)
```
14:21:25 preCheck 0 de 1 · attemptStarted · agentSummoned t1
14:22:02 commitSeen 179c681 · check exit 0 · gate exit 0
14:22:12 verdict passou (correcao/sonnet approve, 0 achados)
14:22:13 landGateStarted · landGateFinished exit 0 em 0 s
14:22:13 landCiStarted
14:22:13.666 STOP -> collie work stop      -> {"state":"stopped"} rc 0 (resposta em 39 ms)
14:22:13 stopRequested
14:22:13 landCiFinished exit 137 em 0 s
14:22:14 stopped "pedido pelo dono (work stop)"
```
`stopReason`: `{"code":"requested","detail":"land"}`

## Respostas
- **Tempo de parada:** ~1 s entre o pedido (14:22:13.666) e o `stopped` (14:22:14). No S9b foram 38 s.
- **CI interrompido? SIM.** `landCiFinished exit 137 em 0 s` (137 = SIGKILL). O processo `run-tests.sh` aparece vivo às 14:22:13.650 e some às 14:22:14.229; continuou ausente nas 5 checagens depois do fim. O `sleep 40` não chegou ao fim.
- **Commit descartado? SIM, com patch e nota.**
  - Nota: "[loop] auto-land: nada integrado, então descartei do cercado os commits da tentativa (1a4a61cf1bf2..179c68133027): 179c681 feat(calc): add negate with test_negate. Arquivos: calc.py, tests/test_calc.py. O cercado voltou a 1a4a61cf1bf2. Patch: ~/Library/Application Support/Collie/work-loops/e84c0863-650e-4d66-b9ed-1316833a61a0/discarded/2026-11-25-112214-179c68133027.patch. Para recuperar, no cercado: git am '…patch'"
- **Tarefa reaberta? SIM.** Nota "[reopen] S9c negate…: feita, mas os commits foram descartados do cercado" + "Reabertas (voltam à fila): … [598c8f14]"; a tarefa 598c8f14 está `open`.
- **Cercado limpo? SIM.** `git status --short` vazio; HEAD 1a4a61c = base; `git log <base>..HEAD` vazio (sem sobra para o próximo land).
- **Nada integrado:** a base continua em 1a4a61c (BASE0).

## Base / remoto
```
$ git -C repo log --oneline -3
1a4a61c e2e: S9c, reintroduce CI sleep 40
994bde1 Land paddock (auto-land): S10 adultera
f289b09 feat(calc): add half with test_half

$ git -C origin.git log --oneline
b8e3f6c e2e fixture: calc with unittest, gate and factory profile
```

## ESPERADO x OBTIDO
ESPERADO: nada integrado depois do pedido (base na BASE0), stopReason de parada do dono (não `landed`), commits descartados ou notados, cercado limpo.
OBTIDO: base em BASE0 ✅ · `requested`/`land` ✅ · CI do land morto na hora (exit 137) e parada em ~1 s ✅ · commit 179c681 descartado, com patch e nota ✅ · tarefa reaberta ✅ · cercado limpo ✅.
Comparando com o S9b: os três defeitos de lá foram corrigidos (agora existe evento de CI no diário, o stop interrompe o CI, e o commit é descartado e a tarefa reaberta).
