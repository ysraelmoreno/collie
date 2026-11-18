# A2.3 Auditoria: sleep e escapes de concorrência

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-a2-lint-catraca.md`. Só documento, nenhuma mudança de código.

## Fazer

`docs/superpowers/roadmap/2026-11-18-confianca/audit-sleep-concurrency.md`: uma tabela por regra (`sleep`,
`unsafe-concurrency`) com **toda** linha de `scripts/ci/lint-baseline.txt` dessas regras: arquivo, n, classificação por
ocorrência (`legítimo`: polling de processo externo, backoff de rede, animação; `remendo`: espera por estado que o
próprio Collie produz, sincronização por tempo, Sendable para calar o compilador), `arquivo:linha`, e, para cada
remendo, a troca proposta (continuation, AsyncStream, actor, notificação) e o teste que provaria a troca.
Fim do documento: os 5 remendos de maior risco, em ordem, como candidatos a tarefas da próxima onda.
Ler o código de cada ocorrência; não classificar por nome de arquivo.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
