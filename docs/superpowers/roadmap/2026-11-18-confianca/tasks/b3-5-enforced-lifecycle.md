# B3.5 Item imposto: injeção, ciclo de vida e métricas

Achados 2, 3 e 6 da revisão da onda 3 (`.collie/briefs/rev-wave3-report.md`, local).

## Fazer

1. **Injeção** (`Sources/CollieDaemonKit/Memory/MemoryService.swift`, `contextParts`, por volta de 351-389, usado por `memory.hookContext` e `memory.context`): item com `enforcedBy` fora de `ok`/`pool`/índice e das **fixadas** (uma fixada imposta também sai: quem impôs decidiu). O corpo e o título dele não aparecem no contexto de início de sessão.
2. **Ciclo de vida** (`LifecycleRules.swift`, `unusedPlan`): item com `enforcedBy` não é arquivado por "sem uso" (nunca é injetado, então nunca ganha uso). Continua pesquisável e sai do TTL.
3. **Métricas** (`MemoryObservability.swift`, `usage.dead`): item imposto não conta como morto; `memory stats` ganha `enforced: N` à parte.

## Testes (escrever antes)

`ChecklistTests`/`MemoryHookTests`: a asserção atual do item imposto procura `] Título` e deixa o índice passar; trocar por `!out.contains("Título")` no contexto de início de sessão, no longo prazo e nas fixadas. `LifecycleInjectionTests` ou `LifecycleRulesTests`: provisório imposto passado do TTL não é arquivado. `MemoryObservabilityTests`: imposto não entra em `dead`, entra em `enforced`.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests` (essa suíte sobe terminais e falha com "closed" no sandbox), nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar em scripts/ci/ nem em architecture-rules.txt.
