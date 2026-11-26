# ma1: injeção sem repetir na sessão e sem ciclo vicioso

Laço A da revalidação da memória (`.collie/briefs/rev-memoria-rag.md`, ponto 3; leia). Check: `scripts/check-memory-a.sh ma1` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- **3a. Dedup durável por sessão.** Em `MemoryService` (injeção de prompt, perto de `hits`, e `context`/SessionStart), o conjunto "já visto" do terminal passa a ser a **união** do que está em memória com `lifecycle.injected(session:)` (LifecycleStore.swift:176, já persistido). Restart do daemon, troca de lote (`sync`) e SessionStart **não** zeram o que a sessão já recebeu (a substituição em `injected[terminal] = …` perto da linha 314 deixa de apagar o histórico da mesma sessão; um `compact` pode reinjetar no máximo uma vez cada id).
- **3e. Cortar o ciclo vicioso.** A injeção automática (`hits`, MemoryService.swift:765) **não** chama `noteRead`; `reads` passa a contar só `memory get` e `memory search` (MemoryCommands.swift:116 e :191 ficam).
## Critérios de aceite (testes em `MemoryDedupDurableTests`, ≥ 6)
- Mesma sessão, restart do daemon simulado (novo `MemoryService` sobre o mesmo store): o id já injetado não volta.
- SessionStart (startup/resume/clear) e troca de lote não apagam o que a sessão recebeu; `compact` permite uma única reinjeção.
- Sessões diferentes continuam recebendo o mesmo id (a dedup é por sessão).
- Injeção automática não muda `reads`; `get` e `search` mudam.
- `InjectionDedupTests`, `LifecycleInjectionTests`, `MemoryHookTests` e `PastorContextLifecycleTests` continuam passando.
## Resultado
(o laço preenche)
