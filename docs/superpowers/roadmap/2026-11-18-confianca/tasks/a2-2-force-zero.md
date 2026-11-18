# A2.2 Zerar `try!` e `as!`

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-a2-lint-catraca.md`. São 8 ocorrências em `Sources/`
(`grep -rnE 'try!|as! ' Sources`).

## Fazer

Trocar cada uma por código que trata o erro ou prova o tipo: `as?` com `guard` e erro/retorno; regex constante →
`static let` com `try` dentro de um inicializador que falha alto **em teste** (um teste que instancia o regex); casts de
tipo CF → `CFGetTypeID` comparado ao `TypeID` do tipo. Sem mudança de comportamento. Depois:
`scripts/ci/lint.sh --update-baseline` (remove as linhas `force`).

## Testes

Os dos arquivos tocados (`ClaimChecks` → `MemoryTrustTests` ou o que cobre `ClaimChecks`; o check do laço roda a
compilação e os filtros listados lá).

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
