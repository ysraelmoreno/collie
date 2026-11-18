# B5.1 Números do laço

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b5-metrica-confianca.md` (requisito 1). Depende de B1.1.
Código: `Sources/CollieDaemonKit/Work/WorkSummary.swift`, `WorkStatusText.swift`.

## Fazer

1. Função pura `LoopStats(work:)`: tarefas que o laço rodou (`tries != nil`): `done`, `deferred`, `firstTry`
   (feitas com `tries == 1`), `meanTries` (uma casa), `seconds` (soma de `evidence.seconds`).
2. `WorkSummary` inclui os números; `work status` de um trabalho com laço ganha a linha
   `laço: 5/6 feitas · 4 na 1ª · 1 adiada · média 1,4 tentativas · 2h10` (vírgula decimal, duração curta).
3. Trabalho sem laço: nada muda.

## Testes (escrever antes)

`WorkSummaryTests` (números com feitas, adiadas, sem evidência), `WorkStatusTextTests` (linha formatada; ausente sem laço).

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
