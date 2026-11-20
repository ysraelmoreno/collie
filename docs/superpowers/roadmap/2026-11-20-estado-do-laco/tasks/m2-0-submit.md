# M2.0 Envio do prompt: reenviar antes de falhar a tentativa

Leia `onda2.md` e `README.md`. **Aprovada pelo dono em 2026-11-20** (toca no `AskCoordinator`, que a Onda 2 listava como fora do escopo). Código: `Sources/CollieDaemonKit/AskCoordinator.swift` (`confirmSubmit`, `submitConfirm`, `submitConfirmMax`, `submitted`, `finish`, `promptSubmitted`), `Sources/CollieDaemonKit/Work/WorkLoop.swift` (como o laço trata o erro do `ask`), `Tests/CollieDaemonKitTests/AskTests.swift` (os testes existentes do `AskCoordinator`).

## Problema (evidência de 2026-11-20)

Duas de três tentativas da M1b.2 falharam com `'loop-…' did not submit the prompt; it may still be in its input`, sem o agente ter feito nada; a tentativa foi **queimada**. `confirmSubmit` conclui que o prompt ficou preso no input quando, passado `submitConfirm` sem o hook `UserPromptSubmit`, o agente não está imprimindo, o `SessionStart` já foi visto e não há aprovação pendente. Com a máquina sob carga (builds de outras sessões), a TUI demora para aceitar o texto e o Enter chega antes de ela estar pronta: o prompt fica digitado e **nada o submete**. A única recuperação hoje é falhar.

## Fazer

1. Em `confirmSubmit`, no ponto que hoje falha com `did not submit`: **antes de falhar, reenvie o Enter uma vez** (o mesmo caminho que envia o Enter depois do paste; não digite o prompt de novo) e espere mais `submitConfirm` pelo hook. Só se continuar sem `UserPromptSubmit` e sem saída, falhe como hoje. Um segundo reenvio nunca: no máximo **um por prompt**.
2. **Não reenvie** quando houver sinal de que o agente está ocupado: imprimindo (`lastOutputAt` dentro de `workingWindow`), com aprovação pendente, ou com um diálogo de pergunta aberto (um Enter nesses casos responderia o diálogo: é a armadilha do texto injetado virar resposta). Esses casos mantêm o comportamento de hoje (`submitted(...)`).
3. O reenvio é **registrado**: um `MemoryEvent`/log do daemon com o terminal e o id do ask (um evento `submitRetried`, no estilo de `askDelivered`) e, para o laço, uma entrada no diário (`LoopEvent.Kind.resubmitted`, detail: o nome do terminal) quando o `ask` do laço passou por um reenvio. O `Kind` novo decodifica de forma tolerante.
4. O erro final (`did not submit`) continua igual para quem já o trata, mas agora só acontece depois do reenvio.
5. Sem `sleep` novo: use a mesma espera que o laço do `confirmSubmit` já usa (o `Task.sleep` existente de 100 ms), sem acrescentar outro.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/AskSubmitRetryTests.swift`

Com o alvo falso que `AskTests` já usa: (a) sem `UserPromptSubmit` e quieto, **um** Enter extra é enviado e, se o hook chega depois do reenvio, o ask segue normalmente (`submitted`); (b) se não chega nem depois do reenvio, falha com `did not submit`, e **só um** reenvio foi feito; (c) com o agente imprimindo, com aprovação pendente ou com sessão sem hook (`!sessionHooked`), **nenhum** reenvio e o comportamento de hoje; (d) o reenvio vira evento. Os testes de `AskTests` seguem verdes **sem mudar expectativa**.
