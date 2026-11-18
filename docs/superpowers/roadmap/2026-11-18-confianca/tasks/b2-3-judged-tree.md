# B2.3 O portão julga a árvore que o check julgou

Achado 1 da revisão da onda 2 (`.collie/briefs/rev-wave2-report.md`, local). Arquivo: `Sources/CollieDaemonKit/Work/WorkLoop.swift`, fluxo da tentativa (por volta das linhas 137-192).

## Fazer

1. Antes de rodar o check, guardar `judged = git rev-parse HEAD` (o commit que o agente deixou).
2. Entre o check e o portão: `git reset -q --hard <judged>` e remover os arquivos não rastreados que o check criou (preservando o que o laço já preserva em `keep`). O portão precisa julgar exatamente a árvore do commit `judged`.
3. Depois do check e do portão: se `HEAD != judged` (o check ou o portão comitou), a tentativa reprova com a razão "o check moveu o HEAD" e o branch volta a `judged` com `reset --hard`.
4. A evidência (`commits`, `shortstat`) é calculada de `before..judged`, não de `before..HEAD` lido depois.
5. O portão só roda se o check passou e já não há razão de reprovar (`committed == false` ou `dirty == true` pulam o portão, sem gastar orçamento).

## Testes (Swift Testing, em `WorkLoopTests`)

- check que edita um arquivo rastreado e sai 0: o portão vê a árvore original (reprova se o commit sozinho reprova).
- check que faz `git commit`: tentativa reprova, HEAD volta a `judged`, evidência sem esse commit.
- portão que faz `git commit`: idem.
- `committed == false` ou `dirty == true`: o portão não é chamado.

## Fora
Não mudar o protocolo nem o formato do registro de trabalhos.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar nos arquivos de `scripts/ci/` nem em `architecture-rules.txt`.
