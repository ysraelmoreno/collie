# B3.3 Checagem sumiu: armadilha volta

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b3-armadilha-regra.md` (requisito 5). Depende de B3.1.
Código: `Sources/CollieDaemonKit/Memory/MapDrift.swift` (`mapDriftPass`, `GitFacts`).

## Fazer

No mesmo passe da deriva de mapa: item com `enforcedBy` cujo caminho não existe no HEAD → limpa `enforcedBy`, grava
`LifecycleFlag(verdict: .outdated, session: "claim-check", …)` com motivo `enforcedBy gone: <caminho>` (cortado em
`CuratorOps.lineMax`), evento no log. Um passe que não consegue consultar o git não mexe em nada.

## Testes (escrever antes)

`MapDriftPassTests`: caminho existe → nada muda; caminho sumiu → limpo e sinalizado; git indisponível → nada muda.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
