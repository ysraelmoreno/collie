# P3: "did not submit the prompt" também é prompt não entregue

Achado de 2026-11-24 (C3b, 3 tentativas): turnos de 7 s e 29 s com o agente ocupado, sem commit, e a última falha foi `'<terminal>' did not submit the prompt; it may still be in its input. Check it with `collie check``, com a máquina em load average acima de 200. As duas primeiras caíram no caminho "turno vencido" e gastaram a tentativa; a terceira foi adiada.

Causa lida no código: `Sources/CollieDaemonKit/AskCoordinator.swift` ~1031 falha com `ProtocolError(code: .unavailable, "…did not submit the prompt…")`, e `AskCoordinator.promptNotDelivered(_:)` (~689, criado no P2) só reconhece `.timeout` com "prompt not delivered" ou "not accepting input". Logo o P2 não cobre esse caso.

## O que fazer
1. Estenda `promptNotDelivered` para reconhecer também `.unavailable` com "did not submit the prompt". Nada mais muda na classificação (um `.unavailable` de outro tipo, como terminal sumido, NÃO é não-entregue).
2. O caminho do P2 (refeita grátis, no máximo 2 por TAREFA, só no prompt INICIAL da tentativa, 20 s de recuo, diário `promptRetry`) passa a valer para esse erro. Quem trata hoje o erro como turno vencido ("o turno acabou em 7 s com o agente ainda ocupado e sem commit") deve consultar `promptNotDelivered` primeiro.
3. `P1`: a causa do revisor mudo (`WorkLoopReview`) também usa `promptNotDelivered` (já corrigido no C1; confirme que cobre esse erro).
4. Nota ao dono quando as 2 refeitas se esgotam: já existe (load average); confirme que cita esta causa.

## Testes
`promptNotDelivered` classifica as 5 mensagens (as 4 antigas e "did not submit the prompt" `.unavailable`) como sim e "No reply from", `.notRunning` e um `.unavailable` genérico como não. A máquina: não submetido na 1ª tentativa refaz sem contar; o teto de 2 por tarefa vale. Reaproveite os hosts falsos de `AttemptMachineTests`/`WorkLoopTests`.

Check: `scripts/check-autoland-loop.sh p3`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
