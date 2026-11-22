# M5.1 Avisos do laço: padrão `end` e agrupamento

Leia `onda5-economia-de-tokens.md` e `onda3c.md` (M3c.4 acrescenta `--notify task|end`, padrão `task`; já no branch quando esta rodar). Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`taskEnded` ~40/57/536), `WorkStatusText.swift` (`taskEnded`, `loopEnded`), `WorkLoopCommands.swift`, `CollieOrientation.swift`.

## Fazer
1. O **padrão** de `--notify` passa a `end` (aviso por tarefa só se pedir `--notify task`). `end` continua avisando fim do laço, tarefa **adiada**, qualquer parada e o aviso de início. `work status`/`work wait` não mudam (é o canal de leitura).
2. **Agrupar:** avisos que o laço ainda envia ao mesmo terminal dentro de uma janela de **60 s** viram **um** aviso de uma linha com as contagens (`3 tarefas feitas · 1 adiada`), com um relógio injetável (`host.now()`), sem `sleep` nem timer de parede; o último aviso do laço (fim/parada) nunca é atrasado: sai na hora e leva o resumo do que estava pendente.
3. Estado antigo sem o campo de `notify` decodifica como o **novo padrão** só para laços **novos**; laços em andamento antes da atualização mantêm `task`.
4. Orientação do Pastor e `/collie:loop`: dizer que os avisos por tarefa são desligados por padrão e que o estado se lê com `work wait` longo (limite de 1500 caracteres em todos os níveis).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopNoticePolicyTests.swift`
Host falso: laço novo sem flag não avisa tarefa feita; `--notify task` avisa como antes; adiada/parada/fim sempre avisam; avisos dentro de 60 s (relógio falso) viram um com contagens; o aviso final sai na hora e inclui o pendente; laço antigo mantém `task`; texto da orientação cabe no limite. Testes de aviso existentes: ajuste só os que dependiam do padrão antigo, e **diga no commit quais**.
