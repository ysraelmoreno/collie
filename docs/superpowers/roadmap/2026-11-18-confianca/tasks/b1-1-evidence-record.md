# B1.1 Gravar a evidência da tarefa aprovada

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b1-evidencia.md` (requisitos 1–2).
Código: `Sources/CollieCore/Work.swift` (`WorkTask`), `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`attempt`,
ramo `if passed`).

## Fazer

1. `public struct TaskEvidence: Codable, Sendable, Equatable` em `Work.swift`: `commits: [String]`, `shortstat: String`,
   `checkTail: String`, `seconds: Int`, `attempt: Int`. `WorkTask.evidence: TaskEvidence?` (decodifica antigos).
2. No ramo de sucesso: `git log --format=%h %s before..HEAD` (no máximo 20), `git diff --shortstat before HEAD`, últimas
   20 linhas da saída do check (e do portão, se houver) passadas por `LotBoards.scrub`, cortadas em 2000 caracteres;
   `seconds` = agora − início da tentativa. Usar o mesmo `out(...)` de git do laço (filtros do repo desligados).
3. Falha não grava evidência; uma tarefa que volta a abrir (`work reopen`) perde a evidência antiga.

## Testes (escrever antes)

`WorkLoopTests`: tentativa aprovada grava commits/shortstat/checkTail/attempt; reprovada não grava; segredo na saída
do check sai mascarado. `WorkStoreTests`: JSON antigo sem `evidence` decodifica.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
