# A1.1 Script de testes afetados

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-a1-ci-pr.md` (requisitos 1–4 e 6).

## Fazer

1. `scripts/ci/affected-tests.sh [<base>]` (sh/bash, `set -eu`): arquivos mudados entre `<base>` (padrão
   `origin/main`; usar `git merge-base`) e `HEAD`. `--files <f>…` recebe a lista direto, sem git.
2. Grafo de targets: `swift package dump-package` + `jq`. Fecho transitivo reverso: quem depende de quem.
3. Saída, uma linha no stdout:
   - vazia: só arquivos fora de `Sources/`, `Tests/`, `Package.*`, `Resources/`, `scripts/ci/`;
   - `ALL`: `Package.swift`, `Package.resolved`, `Resources/…` ou `Tests/Fixtures/…`;
   - senão, test targets afetados separados por `|`, ordenados, sem repetição (ex.: `CollieAppTests|CollieThemeTests`).
   - `Sources/<T>/…` → todo test target que depende de `<T>` direta ou transitivamente.
   - `Tests/<X>/…` → `<X>`. `scripts/ci/…` → vazio para testes Swift (os scripts têm teste próprio).
4. `scripts/ci/test-affected-tests.sh` no estilo de `scripts/ci/test-update-pin.sh` (`fail()`, saída `ok`). Casos:
   doc só → vazio; `Sources/CollieTheme/x.swift` → contém `CollieThemeTests` e `CollieAppTests`, não contém
   `CollieNetworkTests`; `Sources/CollieProtocol/x.swift` → contém `CollieDaemonKitTests`;
   `Tests/CollieCoreTests/x.swift` → exatamente `CollieCoreTests`; `Package.swift` → `ALL`.
5. Executáveis com `chmod +x`.

## Aceite

O check do laço roda o teste acima e mais asserções próprias sobre `--files`.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
