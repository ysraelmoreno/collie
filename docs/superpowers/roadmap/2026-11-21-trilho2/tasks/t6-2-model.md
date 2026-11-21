# T6.2 Modelo do app: `LoopSection` e `HistoryRow`

Leia `README.md`. UI sem views ainda. Código: `Sources/CollieApp/AgentTree.swift` (estilo de modelo puro com tabela de testes), `Sources/CollieClient/DaemonClient.swift` (como o app já obtém `work.*`), `Sources/ColliePlugins/WorkPanel.swift`.

## Fazer
1. **`LoopSection`** (puro, `Equatable`): entrada = o trabalho ativo do cercado atual (ou nenhum) e o estado do laço; saída `visible: Bool` e `rows: [TaskRow]` (`id, title, state (.done/.running/.deferred/.open), tries, max`) mais `header` (fase em texto curto, "desde hh:mm", progresso `n/m`). **Visível só quando** há trabalho ativo e o laço está **rodando** (fase de tentativa, check ou portão); **oculto** sem trabalho, trabalho sem laço, laço terminado ou parado.
2. **`HistoryRow`** (puro): de uma linha de `work.history` (`id,title,openedAt,closedAt,stopReason,done,total,deferred,durationSeconds`) para `{title, whenText ("21/11 02:02"), resultText ("4/6 feitas · 1 adiada"), stopText (motivo curto), durationText ("1h54")}`; fuso local, locale pt-BR; pega `stopReason` desconhecido sem quebrar.
3. **Feed no `DaemonClient`:** `loopState` do trabalho ativo do cercado atual e `history` (últimos 20, via `work.history`), atualizados por `work.wait` (nunca por polling com `sleep`): o app guarda a versão e pede de novo ao mudar; ao trocar de cercado recarrega. Falha do daemon = estado vazio, nunca quebra o painel.

## Testes (escrever antes) — novo `Tests/CollieAppTests/LoopSectionTests.swift`
Tabela de visibilidade (sem trabalho, sem laço, rodando em cada fase, terminado, parado, trabalho de outro cercado); `rows` na ordem das tarefas; `HistoryRow` para: laço bem sucedido, adiadas, parado por orçamento, motivo desconhecido, duração < 1 min, > 1 dia, data de ontem; feed: trocar de cercado recarrega, erro do daemon vira vazio.
