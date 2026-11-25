# RESULTS S7 — teto diário (`specs/s7-absval.md`)

BASE0: 54376c8aceb9cc950d3d6a5cb6fb9bf109e70a07 (após `git merge main --no-edit`: fast-forward 77ab271..54376c8). Cercado limpo.
Remoto: só `b8e3f6c` antes e depois.
Lands nas últimas 24 h antes do S7: S1, S3, S5b, S6b, S6a = 5 (teto do perfil `autoLandPerDay` = 5).

Comandos:
```
collie work start "S7 teto"                                   -> 375e7c29-8ad9-482d-a8f2-4eafc693806c
collie work task add "S7 absval" --spec specs/s7-absval.md \
  --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def absval" calc.py'   -> 1f5ec8a5
collie work run --max 3 --review --auto-land                  -> state starting (aceito, sem recusa prévia)
```

## Execução 1 (11:35:39–11:37:03 UTC)
- preCheck 0 de 1 passa · attemptStarted · agentSummoned t1 · 11:35:46 turnEnded "timeout: target 's7-teto-s7-absval-t1' is not accepting input" → promptRetry 1/2
- 11:36:48 commitSeen 2d6ed31 · check exit 0 · gate exit 0 · 11:37:01 verdict passou (correcao/sonnet approve, 0 achados)
- 11:37:03 **stopped: "auto-land: teto diário do cercado atingido (5 de 5 em 24 h); chame o dono"**
- `stopReason`: `{"code":"landDailyCap","detail":"5 de 5 em 24 h"}`
- Notes: "auto-land: teto diário atingido (5 de 5 em 24 h); nada integrado" · "[reopen] S7 absval: feita, mas os commits foram descartados do cercado" · "descartei do cercado os commits da tentativa (54376c8aceb9..2d6ed31e7f48) … O cercado voltou a 54376c8aceb9. Patch: …/work-loops/375e7c29…/discarded/2026-11-25-083703-2d6ed31e7f48.patch … Reabertas (voltam à fila): S7 absval [1f5ec8a5]"

## Reabrir / 2º run
- `collie work task reopen 1f5ec8a5` → `collie: a tarefa já está aberta; não há o que reabrir` (rc=1): o próprio laço já a reabriu.
- `collie work reopen` não se aplica (trabalho ainda aberto).
- `collie work run --max 3 --review --auto-land` de novo → aceito (`starting`).

## Execução 2 (11:37:37–11:38:33 UTC)
- agentSummoned t1 · 11:38:16 commitSeen 9c72278 · check exit 0 · gate exit 0 · 11:38:27 verdict passou (correcao approve)
- 11:38:33 **stopped: teto diário do cercado atingido (5 de 5 em 24 h)** — `stopReason` `landDailyCap` / `5 de 5 em 24 h`
- Notes: mesmo par "nada integrado" + "descartei … (54376c8aceb9..9c722782f4ac) … O cercado voltou a 54376c8aceb9"; patch guardado.

Fechado com `collie work done` → `{"id":"375e7c29-…"}` (sem pedir confirmação).

## Base
```
$ git -C repo log --oneline -5
54376c8 Land paddock (auto-land): S6a mod
77ab271 feat(calc): add mod with test_mod
6bb2de6 Land paddock (auto-land): S6b power
9a9c1b1 feat(calc): add power with test_power
9521131 e2e: specs S6 to S10
```
Cercado: HEAD 54376c8, limpo (commits 2d6ed31 e 9c72278 descartados, recuperáveis por `git am` do patch).
Remoto: `b8e3f6c` só.

## Observações
- O teto é checado só na hora do land (antes do 1º land), não no `work run`: os dois runs gastaram agente + revisão (~67 mil tokens cada) para depois recusar. Conforme doc (`landDailyCap`: "antes do primeiro land ou antes do próximo trabalho da corrente"), mas seria mais barato recusar já no `work run` quando o teto está esgotado.
- O aviso "[collie] Laço de "S7 teto" parou …" do run 1 chegou só depois que o run 2 já tinha começado (aviso atrasado ~2 min); fácil confundir com o fim do run 2.
- `work status --events` depois do 2º run mostrou por um tempo diário/notes do run anterior (status velho); `work get <id>` estava certo.
- Diferente do S4 (armadilha 15053c3a), aqui o laço descartou os commits da tentativa que não integrou: o cercado não carrega lixo para o próximo land.

## ESPERADO x OBTIDO
ESPERADO: `landDailyCap` (5 de 5 em 24 h), nada integrado; reabrir/rodar de novo: teto continua.
OBTIDO: run 1 `landDailyCap` "5 de 5 em 24 h", nada integrado; tarefa reaberta automaticamente (`task reopen` recusou "já está aberta"); run 2 `landDailyCap` "5 de 5 em 24 h" de novo, nada integrado. Teto não zerou. Base e remoto intactos. ✅
