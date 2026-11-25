# A7: lote 3 (S6, S7, S8), cercado `e2e-fabrica`

Mesmas regras do lote 2 (`A7-DRIVER-2.md`: nunca push nem `paddock land` à mão; `git merge main --no-edit` e BASE0 antes de cada cenário; espere com `collie work wait` em segundo plano; grave `RESULTS-<cenário>.md` em `~/Documents/codes/collie-e2e/e2e1/` com status/eventos, notes, `git -C <base> log --oneline -5`, `stopReason`, o remoto e ESPERADO x OBTIDO). O teto diário do perfil é 5 e a base já tem 3 lands nas últimas 24 h (S1, S3, S5b).

## S6: fila, dois trabalhos (`specs/s6a-mod.md`, `specs/s6b-power.md`)
1. `collie work start "S6a mod"`; task `--spec specs/s6a-mod.md --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def mod" calc.py'`; `collie work run --max 3 --review --auto-land --queue` (entra na fila, não roda).
2. `collie work start "S6b power"` (se recusar porque há um trabalho aprovado na fila, descreva a mensagem e tente de outro jeito); task análoga para `power`; `collie work run --max 6 --review --auto-land --auto-land-max 2`.
ESPERADO: o S6b roda e integra, a corrente ativa o S6a (da fila) e integra; dois lands (lands do dia: 5); `stopReason` `landed` (2 integrados, fila vazia). Registre a ordem, os dois `before/after` e se o `queueEmpty`/`landed` bate com o doc `docs/fabrica/auto-land.md` (no repositório do Collie).

## S7: teto diário (`specs/s7-absval.md`)
`collie work start "S7 teto"`; task `--check '... grep -q "def absval" calc.py'`; `collie work run --max 3 --review --auto-land`.
ESPERADO: `landDailyCap` (5 de 5 em 24 h), nada integrado. Depois `collie work reopen` na tarefa (se existir) ou `work run` de novo: o teto CONTINUA valendo (não zera). Registre as duas.

## S8: recusas
a) `collie work run --max 1 --auto-land --no-review` (com um trabalho/tarefa aberta qualquer): ESPERADO recusa mencionando a revisão.
b) `collie paddock factory e2e-fabrica off` e `collie paddock create zz --factory` pelo SEU terminal: ESPERADO recusa "só o dono"; confirme que a marca segue ligada (`collie paddock list`).
c) Grave as mensagens exatas.

S9 e S10 ficam para o lote 4: o teto diário (5) estará esgotado depois do S7, e o dono sobe o teto antes.
