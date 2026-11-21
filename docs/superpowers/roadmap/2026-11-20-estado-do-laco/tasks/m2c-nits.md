# M2c Pontas da revisão da Onda 2b

Leia `README.md` (regras aprendidas) e `.collie/briefs/rev-onda2b-report.md` se existir (achados 1, 2 e 4). Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (linhas ~147, ~388 e `adoptable`, ~517-530), `Sources/CollieDaemonKit/WorkLoopCommands.swift` (~229), `Tests/CollieDaemonKitTests/LoopResumeSafetyTests.swift` (~213).

## Fazer

1. **`resumeAt` não avança numa adoção.** No início de uma tentativa que adota (`resumeFrom` vivo da própria tarefa), mantenha o `resumeAt` que já existe em vez de zerar; se a adoção for cancelada (`uncount`) não o sobrescreva com a hora nova; o varredor (`stopLoopsLeftRunning`) só grava `resumeAt` quando ainda não há um. Uma tentativa **sem** adoção continua zerando `resumeAt`, e os `resumeFrom` das outras tarefas continuam sendo limpos.
2. **Resolução de segundos.** A comparação da data do committer (`%ct`, inteiro) com `resumeAt` (fração) passa a ser `ct < floor(resumeAt)` ... use `Double(ct) <= floor(resumeAt) - 1` só se a leitura ficar mais clara; o que importa: um commit feito no mesmo segundo de `resumeAt` ou depois **não** é adotado. Na dúvida, não adota.
3. **Asserção do teste (g).** Em `LoopResumeSafetyTests.swift` (~213) troque `||` por `&&` (os três campos ficam `nil`).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopResumeNitsTests.swift`

(a) adoção cancelada e retomada: `resumeAt` continua o da primeira queda; (b) varredor com `resumeAt` já gravado não o troca; (c) tentativa sem adoção zera `resumeAt` e limpa `resumeFrom` alheio; (d) commit no mesmo segundo de `resumeAt` não é adotado, um segundo antes é. Os testes de `LoopResumeSafetyTests` e `LoopResumeTests` seguem verdes sem mudar expectativa (exceto a asserção do item 3).
