# M8.1 Tentativa corrente certa; histórico só de trabalhos reais

Leia `onda8.md`. Código: `Sources/CollieApp/LoopSection.swift` (`TaskRow`, `make`), `Sources/CollieDaemonKit/Work/WorkLoopLanes.swift` e `WorkLoop*.swift` (`WorkTask.tries` só sobe **no fim** da tentativa: a em curso é `tries + 1`), o handler do comando `work.history` e `WorkArchiveFiles.swift`.

## Fazer
1. **Tentativa corrente:** a linha de uma tarefa `running` mostra `tentativa (tries+1)/max` (nunca acima de `max`); `done`/`deferred` mostram o total usado; `open` não mostra "0/3" (texto vazio ou "—"). `triesText` e `accessibilityLabel` seguem a regra.
2. **Causa dos "trabalhos" de terminal de tentativa** (ex.: `onda-6-achados-da-m6-5-pont…`, 0/0 feitas, <1 min): ache **quem os cria** (o agente da tentativa seguindo a orientação de `work start`? o daemon?) e corrija na origem se for o daemon ou a orientação do agente de laço; registre a causa no relatório da tarefa.
3. **Histórico:** `work.history` (e o resumo imutável/arquivo) **não** lista trabalho com **zero tarefas** e sem laço. Trabalhos antigos já gravados: filtrados na leitura, nada é apagado.

## Testes (escrever antes) — `Tests/CollieAppTests/LoopSectionAttemptTests.swift` e `Tests/CollieDaemonKitTests/HistoryRealWorksTests.swift`
Linha rodando com `tries=1,max=3` → "tentativa 2/3"; `tries=3,max=3` rodando → "3/3"; aberta → sem "0/3"; concluída → total usado. Histórico: trabalho com 0 tarefas sem laço não aparece; com laço (mesmo 0 feitas) aparece; o fake do daemon **aplica a regra real**; ponta a ponta: um trabalho fechado real aparece, um vazio não.
