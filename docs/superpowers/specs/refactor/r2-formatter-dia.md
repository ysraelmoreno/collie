# R2: um só formatter de dia na memória

Origem: auditoria de simplicidade de 2026-11-23. O mesmo `ISO8601DateFormatter` com `[.withFullDate]` existe 3 vezes em `Sources/CollieDaemonKit/Memory/`: `MemoryService.swift` (~949, `private static let dayFormatter`), `LifecycleRules.swift` (~91, igual) e `LifecyclePass.swift` (~14, criado a cada passada).

Fazer: UM `static let dayFormatter` (UTC, só leitura depois do init) num só lugar do módulo Memory, e os outros dois usam esse. Mantenha o comentário de que é só leitura e o `nonisolated(unsafe)` somente onde ele for realmente necessário. Comportamento idêntico.

ATENÇÃO (o gate): o lint do repositório tem uma catraca de `unsafe-concurrency` (`scripts/ci/lint-baseline.txt`, regra `nonisolated(unsafe)`). Remover duas declarações faz o número CAIR, e o gate (`scripts/ci/lint.sh`) falha até o baseline ser baixado: rode `scripts/ci/lint.sh --update-baseline` e inclua `scripts/ci/lint-baseline.txt` no commit. Nunca suba o baseline à mão.

Check: `scripts/check-refactor-loop.sh r2`. Commit ao final, só os arquivos da tarefa.
