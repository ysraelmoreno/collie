# B5.2 Commits do laço revertidos

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b5-metrica-confianca.md` (requisito 2). Depende de B5.1.

## Fazer

1. Ao montar o resumo (não no caminho quente): para cada commit em `evidence.commits`, `git rev-parse` do short sha;
   procura no branch atual `git log --grep "This reverts commit <sha>" --format=%h`. Commit que não resolve mais (rebase)
   conta como desconhecido, não como revertido.
2. Git com os mesmos cuidados do laço (filtros do repo desligados); em teste, git por um protocolo injetável.
3. `LoopStats` ganha `reverted` e `unknown`; a linha do status mostra `· n revertidos` só quando n > 0.

## Testes (escrever antes)

`WorkSummaryTests`: nenhum revertido; um revertido; sha que não resolve conta como desconhecido.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
