# P2: "prompt não entregue" não é "turno vencido" e não gasta a tentativa

Achado de 2026-11-24 (diário do laço, B1 tentativas 2 e 3): `turnEnded timeout 4s ocupado` e `timeout 3s ocupado`, 2 a 4 s depois de o agente ser convocado, com o turno de 40 min. Padrão que já aparecia na U5, U4 e R3 (cartão do fim de turno prematuro).
As 3 tentativas do B1 coincidiram com a máquina em carga 21 (um build de release rodando junto). Causa provável, lida no código e NÃO reproduzida:
- `AskCoordinator` (`Sources/CollieDaemonKit/AskCoordinator.swift` ~838-845) lança `ProtocolError(code: .timeout, message: "target '…' is not accepting input")` quando a escrita no PTY trava (`PTYError.stalled`), e `timedOut` (~695-703) lança `.timeout` com
  "…produced no output yet; prompt not delivered", "…is not ready yet…; prompt not delivered", "…is still busy…; prompt not delivered".
- `WorkLoop.talk` (`Sources/CollieDaemonKit/Work/WorkLoop.swift` ~918) traduz QUALQUER `.timeout` em `.turnTimedOut`; `AttemptMachine` (~157) trata como "turno vencido, o check decide" e o diário grava só a palavra `timeout`: a mensagem some.
- Resultado: o prompt nunca chegou ao agente, não há commit, a tentativa é gasta como se o agente tivesse falhado. Três assim seguidas adiam a tarefa.

## O que fazer (motor; sem mudar o isolamento nem o resto do laço)
1. **Diagnóstico:** `AttemptMachine.Event.turnTimedOut` passa a carregar a mensagem do erro; o diário grava `turnEnded timeout: <mensagem limpa, até 120 caracteres>` (mesma limpeza do resto do laço). Quando o turno termina com agente `ocupado` e SEM commit em menos de `shortTurn`,
   a nota de falha inclui também as últimas linhas da tela do agente (até 20 linhas, 800 caracteres, limpas e sem segredo pela rotina que o laço já usa nas notas), lidas ANTES do dismiss (`host`: leitura da tela do terminal; reutilize o que `host.usageLimit` lê).
2. **Não entregue não gasta tentativa:** um helper puro e testável (`AskCoordinator.promptNotDelivered(_ e: ProtocolError) -> Bool`: `.timeout` com "prompt not delivered" ou "not accepting input") separa esse caso do timeout de verdade. Nesse caso a máquina NÃO conta a tentativa (como o `usageLimit`/`uncount`, mas
   o laço continua): descarta o agente, espera um recuo (padrão 20 s, injetável nos testes) e refaz a MESMA tentativa com agente novo. No máximo 2 refeitas "grátis" por tarefa; a terceira não entregue conta como tentativa normal (não pode haver laço infinito). Cada refeita vai para o diário (`promptRetry`) e para o resumo.
3. Um `.timeout` de verdade (a resposta venceu depois de entregue: "No reply from … within Ns") segue como hoje.
4. **Aviso ao dono quando a carga é a causa provável:** se uma tarefa gasta as 2 refeitas, a nota diz "prompt não entregue 3 vezes seguidas; a máquina está sobrecarregada?" e inclui o load average (um número) no texto da nota.

## Testes (`Tests/CollieDaemonKitTests`, hosts falsos de `AttemptMachineTests`/`WorkLoopTests`; sem terminais reais nem `sandbox-exec`)
`promptNotDelivered` classifica cada mensagem (as 4 não entregues sim; "No reply from" não; `.notRunning` não). A máquina: não entregue na 1ª tentativa refaz sem contar (`tries` intacto), a 3ª não entregue conta; o timeout verdadeiro não refaz. O diário e a nota trazem a mensagem. O recuo é injetável (teste sem espera de relógio).
Não mude `maxTries`, `deadline` nem a semântica de `usageLimit`.

Check: `scripts/check-autoland-loop.sh p2`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
