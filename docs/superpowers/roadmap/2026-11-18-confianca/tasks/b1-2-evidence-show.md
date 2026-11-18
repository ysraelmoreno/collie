# B1.2 Mostrar a evidência

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b1-evidencia.md` (requisitos 3–5). Depende de B1.1.
Código: `Sources/CollieDaemonKit/Work/WorkStatusText.swift`, `Sources/ColliePlugins/WorkPanel.swift`, o aviso de fim de
laço em `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`[collie] Laço de "…" terminou: …`).

## Fazer

1. `work status`: tarefa feita com evidência → `✓ <título> · tentativa n · k commits · <shortstat>`.
2. Painel do trabalho: na tarefa feita, commits (lista), shortstat, e a cauda do check num bloco expansível (fechado por
   padrão, fonte monoespaçada).
3. Aviso de fim de laço: uma linha por tarefa do laço (feita: commits e shortstat; adiada: razão), respeitando o limite
   de tamanho que o aviso já tem (cortar com "… e mais n").

## Testes (escrever antes)

`WorkStatusTextTests` (linha da tarefa feita, sem evidência fica como hoje), `WorkPanelTests` (modelo do painel expõe
commits/shortstat), `WorkLoopCommandTests` (texto do aviso com feita e adiada).

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
