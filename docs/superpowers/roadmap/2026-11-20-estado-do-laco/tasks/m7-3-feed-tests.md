# M7.3 Testes do feed sem `sleep`; o histórico recarrega no fim do laço de um trabalho fechado

Leia `onda7.md` e os **achados A3, A4 e A7** de `rev-onda6-report.md`. Código: `Tests/CollieClientTests/WorkFeedFollowTests.swift` (~28 `while hold { Task.sleep }`, ~53 `settle` 300×10 ms, ~128/134/149 `Task.sleep(50 ms)` antes de asserts negativos), `Sources/CollieClient/WorkFeed.swift` (~87-91), `Sources/CollieDaemonKit/WorkChatCommands.swift` (~271 `hub.emit(.work)`).

## Fazer
1. **Testes sem relógio:** no daemon falso, trocar `hold`/`settle`/`sleep` por **continuations** e esperas "N chamadas" (`untilCalls(n)`, como o `untilWaiting` do integrador); para os asserts negativos, esperar `inFlight == 0` por continuation e só então contar. A prova da coalescência não pode passar falsamente numa máquina lenta.
2. **Histórico:** quando o laço de um trabalho **fechado com laço rodando** termina e o resumo é gravado, o feed recarrega o histórico (guardar também os ids fechados com laço rodando, ou recarregar o histórico em todo evento de trabalho que não está em `active`).
3. **(Se barato)** o evento `.work` do daemon leva o **cercado**, e o app só relê o que é do cercado atual (já ignorado no feed; o daemon deixa de forçar a releitura de `work.status all:true` por evento de outro cercado).

## Testes (escrever antes) — ajuste `WorkFeedFollowTests` e novo `Tests/CollieClientTests/WorkFeedClosedLoopTests.swift`
Os cenários da M6.2 sem `sleep` (e o lint de testes não acha novo); trabalho fechado com laço rodando: ao fim do laço o histórico mostra a linha **com resumo** (não a reconstruída); evento de outro cercado não causa releitura. Mutação: reverter a coalescência faz o teste **falhar**.
