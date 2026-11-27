# ma2: "uso" só com prompt do usuário

Laço A da revalidação da memória (`.collie/briefs/rev-memoria-rag.md`, pontos 4 e 5; leia). Check: `scripts/check-memory-a.sh ma2` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- **4e.** `resolvePending` (MemoryService.swift:797) e o ponto que o chama (MemoryCommands.swift:281-284) só contam um uso implícito quando o prompt seguinte veio **do usuário** (`asks.provenance.submit`, como no código já existente de proveniência) ou quando a tarefa do laço passou na 1ª tentativa. Um prompt de máquina (ask de agente, retomada do laço) **não** gera uso. Correção do usuário continua contando como correção.
- Documente em comentário por que (o "uso" era vácuo: a maioria dos prompts são asks de máquina).
## Critérios de aceite (testes em `MemoryUseSignalTests`, ≥ 5)
- Prompt do usuário sem correção: uso contado. Ask de máquina: nenhum uso.
- Tarefa de laço passada na 1ª tentativa: uso contado; na 2ª: não.
- Correção do usuário: correção contada como hoje.
- `LifecycleStoreTests`, `LifecyclePassTests` e `MemoryObservabilityTests` continuam passando.
## Resultado
(o laço preenche)
