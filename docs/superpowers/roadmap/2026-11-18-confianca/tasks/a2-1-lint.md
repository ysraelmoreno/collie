# A2.1 Lint em catraca

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-a2-lint-catraca.md` (requisitos 1–7).

## Fazer

1. `scripts/ci/lint.sh`: para cada `Sources/**/*.swift` conta por regra:
   - `sleep`: `Task\.sleep|\.asyncAfter\(|usleep\(|Thread\.sleep`
   - `unsafe-concurrency`: `@unchecked Sendable|nonisolated\(unsafe\)`
   - `force`: `try!|as! `
2. `scripts/ci/lint-baseline.txt`: linhas `<regra> <arquivo> <n>`, ordenadas (`LC_ALL=C sort`), gerado com a contagem
   atual exata.
3. Falha (exit 1) se um arquivo passa do número do baseline ou não está nele: imprime regra, `arquivo:linha` de cada
   ocorrência e a causa raiz (textos do PRD). Também falha se algum arquivo ficou **abaixo** do baseline, mandando rodar
   `scripts/ci/lint.sh --update-baseline`.
4. `--update-baseline`: só abaixa ou remove linhas; se algo precisaria subir ou entrar, recusa (exit 1) e não escreve.
5. Raiz configurável por `LINT_ROOT` (padrão: raiz do repo) para o teste.
6. `scripts/ci/test-lint.sh` (estilo `test-update-pin.sh`, árvore em `mktemp -d`): passa no baseline exato; falha com
   sleep novo; falha com arquivo novo fora do baseline; falha quando abaixo; `--update-baseline` abaixa e depois passa;
   `--update-baseline` recusa subir.
7. Rodar no repo leva < 2 s. Executáveis com `chmod +x`.

## Fora

Não corrigir nenhuma ocorrência existente.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
