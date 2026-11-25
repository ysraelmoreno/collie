# RESULTS S6 — fila, dois trabalhos (refeito 2026-11-25 ~11:24 UTC)

BASE0: 9521131fd0238bc5a5e1252cc86a6ca295f0fe62 · origin: só `b8e3f6c` (inalterado, sem push).
`git merge main --no-edit`: Already up to date. Cercado limpo.

## Setup
- S6a mod [107dd488] (terminal E2e, eu): já estava `queued` (aprovado, na fila) da rodada anterior; `work status`: "na fila do auto-land (aprovado pelo dono; entra depois do próximo land do cercado)".
  (Na rodada anterior: `collie work start "S6b power"` no meu terminal recusou com `collie: work already open: S6a mod`.)
- S6b power [ccef47a3]: delegado a sub-Pastor `collie summon s6b --shepherd` (claude, preset próprio), prompt restrito: só `work start`, `task add --spec specs/s6b-power.md --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def power" calc.py'`, `work run --max 6 --review --auto-land --auto-land-max 2`; proibido editar/commitar; avisos `[collie]` → só "ok". Obedeceu (respondeu "ok" aos avisos; nenhum commit por fora). Dispensado ao fim (`collie dismiss s6b`), pois o recap dele sugeria "decide whether to push".

## Ordem / eventos
S6b power (t1):
- 11:24:54 preCheck 0 de 1 passa · attemptStarted · agentSummoned s6b-power-s6b-power-t1
- 11:25:31 commitSeen 9a9c1b1 · 11:25:32 check exit 0 · othersWaiting "E2e"
- 11:26:09 gate exit 0 · 11:26:20 verdict passou (correcao/sonnet: approve, 0 achados)
- 11:26:26 **landed 9521131 -> 6bb2de6**; nota "próximo trabalho da fila: S6a mod (2 de 2)"

S6a mod (ativado pela corrente):
- 11:26:29 attemptStarted · 11:26:45 turnEnded "timeout: target 's6a-mod-s6a-mod-t1' is not accepting input" → promptRetry 1/2 (não conta tentativa)
- 11:27:06 agentSummoned de novo · 11:27:47 commitSeen 77ab271 · check exit 0 · gate exit 0
- 11:27:56 reviewerMute (correcao sem resposta, prompt não entregue) → reviewRetried → 11:28:06 verdict passou (approve, 0 achados)
- 11:28:08 **landed 6bb2de6 -> 54376c8**

## before/after
1. S6b power: `9521131fd0238bc5a5e1252cc86a6ca295f0fe62 -> 6bb2de6d866fa2dc4c8e184987e0a34ca27fc3e5`
2. S6a mod:  `6bb2de6d866fa2dc4c8e184987e0a34ca27fc3e5 -> 54376c8aceb9cc950d3d6a5cb6fb9bf109e70a07`

## stopReason
- S6b power: `landed` (detalhe `9521131fd023 -> 6bb2de6d866f`)
- S6a mod: `landed` (detalhe `6bb2de6d866f -> 54376c8aceb9`)
- `collie work list` depois: `[]` (fila vazia, nada ativo).

## Notes (trabalhos)
S6b: parecer sem veto (correcao approve) · auto-land integrado por merge local (sem push), desfazer `git reset --hard 9521131…` / `git revert -m 1 6bb2de6…` · próximo da fila S6a mod (2 de 2) · laço terminou: integrado.
S6a: 2× "tirado da fila (work stop)" (rodada anterior) · ativado pela corrente após o land de S6b (2 de 2) · tentativa 1 prompt não entregue, refeita 1/2 sem contar · parecer sem veto (1ª rodada muda, repetida) · integrado · laço terminou.

## Base
```
$ git -C repo log --oneline -5
54376c8 Land paddock (auto-land): S6a mod
77ab271 feat(calc): add mod with test_mod
6bb2de6 Land paddock (auto-land): S6b power
9a9c1b1 feat(calc): add power with test_power
9521131 e2e: specs S6 to S10
```
Remoto: `b8e3f6c e2e fixture: calc with unittest, gate and factory profile` (só).

## Conferência com `docs/fabrica/auto-land.md` (my-orchestrator-memory)
Doc: `landed` = merge feito e a corrente acabou; `queueEmpty` só quando ainda havia teto livre em `--auto-land-max` e a fila acabou; `maxReached` = integrou N e ainda há aprovados esperando.
Aqui: N=2, integrou 2, fila vazia → nem `queueEmpty` (sem teto livre) nem `maxReached` (ninguém esperando) → `landed`. **Bate.** A corrente pegou o aprovado mais antigo (S6a), como o doc diz.

## Observações
- stopReason é registrado por trabalho (cada um `landed` com seu before/after); não há um stopReason único "2 integrados" da corrente.
- O aviso de fim do S6a (trabalho do terminal E2e) chegou ao sub-Pastor s6b (quem iniciou a execução), não ao terminal dono do S6a.
- Flakiness de entrega: prompt não entregue ao agente t1 e ao revisor correcao no S6a; ambos recuperados por retry automático.
- `work history` ainda lista trabalhos-fantasma S6b power (128511fa, 1bc1ccce, 2a8a6322, 0/1, sem stopReason) e 6f464327 `cancelled` da rodada travada anterior.
- Lands no dia agora: S1, S3, S5b, S6b, S6a = 5.

## ESPERADO x OBTIDO
ESPERADO: S6b integra, corrente ativa S6a e integra, 2 lands (dia: 5), `landed`.
OBTIDO: idem — S6b landed (9521131→6bb2de6), depois S6a landed (6bb2de6→54376c8), fila vazia, `landed`, remoto intacto. ✅

---
# Rodada anterior (travada; mantida como registro)

BASE0: 9521131fd0238bc5a5e1252cc86a6ca295f0fe62 · base inalterada · origin só b8e3f6c.

## Linha do tempo
1. S6a: `work run --max 3 --review --auto-land --queue` -> `{"state":"queued"}`. OK.
2. `collie work start "S6b power"` no mesmo terminal: RECUSA `collie: work already open: S6a mod`.
3. Outro jeito: `collie summon s6b` (claude) + `--terminal s6b`: `work run` RECUSA `collie: 'work.run' is for Shepherds (and the app, on a Shepherd's work): a loop summons agents`.
4. `collie summon s6b --shepherd` (claude): run aceito. Mas o sub-Pastor claude recebeu o aviso do laço e fez a tarefa por fora (26727ef) junto com o agente do laço (157c566); correcao vetou (3 major: power e test_power duplicados, 2 commits). stopReason `landReviewVeto`, nada integrado. Depois o s6b ainda deixou d3ceb50 solto no cercado; descartado com `git reset --hard 9521131` (aprovado pelo dono).
5. `collie summon s6b2 --preset shell --shepherd`: o run herdou preset shell nas tentativas -> agente da tentativa era um zsh, recebeu o prompt como comando (`zsh: no matches found: [collie]`), nunca terminou turno.
6. `work stop --terminal s6b2` -> stopRequested (04:05:46) sem fim; work 6f464327 "reconstruído", task inProgress.
7. Desde então todo `work run` no cercado: `collie: a loop is already running in paddock 'e2e-fabrica'; ... collie work stop, from the terminal that started it, ends it`. Não destravou com: dismiss s6b2, dono fechar o terminal da tentativa, novo sub-Pastor s6b3, tirar S6a da fila (`work stop` no meu terminal dequeued S6a; reposto depois).

## ACHADO (bug/armadilha do Collie)
Terminal shell em laço quebra: (a) como agente de tentativa não tem turno, o laço fica preso e o stop nunca conclui, deixando o cercado travado para qualquer work run; (b) como sub-Pastor, recebe avisos `[collie] ...` digitados no zsh. Sem comando de CLI para limpar a trava; só o app. Sugestão: recusar preset shell em work run / sub-Pastor que roda laço, ou dar timeout ao stopRequested.

## Doc auto-land
`docs/fabrica/auto-land.md` não achado no disco. Referência usada: `collie work run --help` (--auto-land-max): landed = N integrados e fila vazia; queueEmpty = menos de N e fila acabou; maxReached = N e ainda há fila. Não verificado na prática (S6 não completou).

## ESPERADO x OBTIDO
ESPERADO: S6b integra, corrente roda S6a, 2 lands, `landed`. OBTIDO: nenhum land; S6 bloqueado (erros de setup meus + trava do laço shell). S6a segue na fila.
