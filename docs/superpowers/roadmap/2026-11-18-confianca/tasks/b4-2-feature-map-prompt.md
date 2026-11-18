# B4.2 O laço aponta o mapa

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b4-mapa-funcionalidades.md` (requisitos 3–4).
Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`prompt`, `attempt`).

## Fazer

1. Na tentativa, se a worktree tem `docs/feature-map.md` (senão `FEATURES.md`), o prompt ganha uma linha:
   `O mapa de funcionalidades do projeto está em <caminho relativo>: use os nomes dele.` Sem arquivo, nada.
   A verificação de existência passa pelo host do laço (testável), não por `FileManager` solto no meio do `prompt`.
2. `docs/referencia.md`: uma linha sobre a convenção na seção do laço.

## Testes (escrever antes)

`WorkLoopTests`: com mapa → linha presente com o caminho; sem → ausente; os dois nomes.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
