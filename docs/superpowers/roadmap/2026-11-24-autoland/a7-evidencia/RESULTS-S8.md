# RESULTS S8 — recusas

BASE0: 54376c8aceb9cc950d3d6a5cb6fb9bf109e70a07 (`git merge main --no-edit`: Already up to date). Cercado limpo. Remoto: só `b8e3f6c` antes e depois.
Trabalho de apoio: `collie work start "S8 recusas"` → 9e24047a-c5c6-499d-98ff-afcab38666db; `collie work task add "S8 qualquer" --check 'true'` → d4bc0c5b.

## a) auto-land sem revisão
```
$ collie work run --max 1 --auto-land --no-review
collie: --auto-land exige revisão: tire --no-review ou ligue factory.review no perfil (ou use --review)
rc=1
```
ESPERADO: recusa mencionando a revisão. OBTIDO: recusa, menciona revisão (`--auto-land exige revisão`), nada rodou. ✅

## b) marca de fábrica pelo terminal do Pastor (E2e)
```
$ collie paddock factory e2e-fabrica off
collie: cercado fábrica: só o dono liga ou desliga (o app ou a CLI do dono), nunca um agente
rc=1

$ collie paddock create zz --factory
collie: cercado fábrica: só o dono liga ou desliga (o app ou a CLI do dono), nunca um agente
rc=1
```
`collie paddock list` depois: `e2e-fabrica (fábrica)	working	collie/e2e-fabrica	…/e2e1/repo/.collie/paddocks/e2e-fabrica` — marca segue ligada; nenhum cercado `zz` criado.
ESPERADO: recusa "só o dono", marca ligada. OBTIDO: idem nas duas. ✅

## Fechamento
`collie work done` → `{"id":"9e24047a-…"}` (sem pedir confirmação, mesmo com tarefa aberta). `collie work list` → `[]`.

## Base
```
$ git -C repo log --oneline -5
54376c8 Land paddock (auto-land): S6a mod
77ab271 feat(calc): add mod with test_mod
6bb2de6 Land paddock (auto-land): S6b power
9a9c1b1 feat(calc): add power with test_power
9521131 e2e: specs S6 to S10
```
Nenhum stopReason (nenhum laço rodou).

## Observação
- `paddock create zz --factory` responde com a mesma mensagem de "liga ou desliga"; podia dizer "criar como fábrica" para ficar claro.
- `work done` fecha sem confirmação um trabalho com tarefa aberta (d4bc0c5b nunca rodou).

## ESPERADO x OBTIDO
a) recusa com revisão ✅ · b) recusa "só o dono" nas duas, marca ligada ✅ · c) mensagens exatas acima.
