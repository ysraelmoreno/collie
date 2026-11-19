# B3.6 Deriva do imposto: sem flag que bloqueia, motivo seguro, candidatas verificadas

Achados 4, 5 (parte da flag) e 7 da revisão da onda 3 (`.collie/briefs/rev-wave3-report.md`, local). Código: `Sources/CollieDaemonKit/Memory/MapDrift.swift` (por volta de 205-225), `LifecycleRules.swift` (`contested`), `PitfallClasses.swift` (`isEnforceCandidate`).

## Fazer

1. Quando a checagem some, a deriva continua limpando `enforcedBy` e voltando o item à injeção, mas **não** grava `LifecycleFlag(.outdated)` que bloqueia o ganho de tier sem re-check. Grava o fato como evento no log de memória e uma linha em "Precisa de você" (ou na saída de `memory stats`), com o caminho **só se `MapDrift.safePath`** (senão, "caminho recusado").
2. `isEnforceCandidate` exige `provenance.isVerified` (contagem, `list --candidates` e topo do `memory stats`).

## Testes (escrever antes)

`MapDriftPassTests`: checagem sumiu → `enforcedBy` limpo, **sem** flag outdated, com evento; item provisório volta e pode ganhar tier depois de usado. Caminho esquisito no motivo → "caminho recusado". `MemoryObservabilityTests`: registro editado à mão (não verificado) com `hits: 99` não é candidata.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests` (essa suíte sobe terminais e falha com "closed" no sandbox), nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar em scripts/ci/ nem em architecture-rules.txt.
