# Revisão independente, rodada 8 (A3 e A4: --review em modo open)

Revisores: seguranca (reject: 1 blocker, 2 minor) e motor-concorrencia (approve, 3 minor, 1 nit). JSON em `rev-f2h/`.

| Achado | Resolução (A5) |
|---|---|
| blocker: o revisor nascia com o modo do workspace; julgado em lane (strict) com workspace open, ou modo mudando no meio, deixava o revisor mais fraco que o julgado | O revisor nasce sempre strict (`launch`, via `loopReviewers`); `summonReviewer` exige `startMode == .strict` |
| minor (ambos): `agentsOpen` lia o modo atual do workspace, não o do agente julgado | `agentsOpen(_ agent:)` olha o `startMode` do terminal julgado |
| minor: doc dizia "no máximo o cala" | `docs/referencia.md`: em open o parecer não isola, só avisa |
| minor: teste só prova o toggle do fake; falta teste de `RouterLoopHost.agentsOpen` | aberto, sem teste do host real (coberto pelas iscas de ponta a ponta) |
| minor: premissa de A4 vs `strictWritable` | aberto; o caso real (open mutou por `~/.claude`) foi medido nas iscas f2b/f2d |
| nit: dois saltos ao actor | aceito |

Após A5 falta uma execução de ponta a ponta com o revisor strict em daemon open (iscas) antes de dar a rodada por fechada.
