# A1.2 Workflow de CI

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-a1-ci-pr.md` (requisito 5). Depende de A1.1, A2.1, A3.1 (os
scripts já estão no repo).

## Fazer

`.github/workflows/ci.yml`:
- `on: pull_request` e `push` em `main`; `concurrency` cancelando execuções velhas do mesmo ref;
- um job, `runs-on: macos-26`, com a mesma seleção de Xcode/Swift do `.github/workflows/release.yml`;
- `actions/checkout` com `fetch-depth: 0`;
- passos: `swift --version`; `scripts/ci/lint.sh`; `scripts/ci/check-architecture.sh`; os três `scripts/ci/test-*.sh`
  novos (affected-tests, lint, check-architecture); `swift build --build-tests`; testes: base = `origin/${{ github.base_ref }}`
  em PR, `HEAD~1` em push; saída vazia → pula; `ALL` → `swift test --disable-sandbox`; senão
  `swift test --disable-sandbox --filter "<saída>"`;
- nenhum `secrets.`; `permissions: contents: read`.

Comentário de 1–2 linhas no topo, no estilo dos outros workflows.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
