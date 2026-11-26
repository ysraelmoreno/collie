# ma4: prune periódico das falhas do curador e motivo nas stats

Laço A da revalidação da memória (`.collie/briefs/rev-memoria-rag.md`, ponto 2; leia). Check: `scripts/check-memory-a.sh ma4` (não o altere). Sem relógio real nem sleep (relógio injetável); só `swift test --filter`.

## O que construir
- **2a.** `Curator.pruneFailed` (Curator.swift:83) também roda no passe de consolidação (a cada ciclo do `consolidate`), não só no load do daemon ou numa falha nova; job em `failed/` com mais de 7 dias some sem restart.
- **2b.** `collie memory stats` ganha `curatorFailuresByReason` (bucket pelo prefixo do `reason` já gravado, Curator.swift:529) e `curatorFailuresByProvider`, em `MemoryObservability` (perto de :206-207). Reason vazio vai para o bucket "unknown".
- **2d.** Chamadas do botão "Testar" (`testCalls`, Curator.swift:324) não entram em `curatorRuns` nem em `curatorRunFailures` (ou ficam marcadas `test: true` e fora das contas).
## Critérios de aceite (testes em `CuratorFailureStatsTests`, ≥ 6)
- Job com mtime de 8 dias em `failed/` desaparece depois de um ciclo de consolidação, sem recriar o serviço.
- 3 eventos sintéticos (2 motivos e 1 vazio) geram 3 buckets; por provedor também.
- Chamada de teste não altera as contagens de rodadas e falhas.
- `ConsolidationTests`, `CuratorQueueTests` e `MemoryObservabilityTests` continuam passando.
## Resultado
(o laço preenche)
