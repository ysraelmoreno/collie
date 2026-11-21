# M3b.6 Pontas da revisão da Onda 3

Leia `onda3b.md` e os **nits 6 e 8** de `rev-onda3-report.md`. Código: `WorkCommands.swift` (~256, `needs`/`scope` lidos com `str(r, …)`), `WorkLoopCommands.swift` (`cancelLoops`, `removeLanes`), `Work/WorkLoopLanes.swift` (~210-212, a `Task` do integrador), `Work/AgentNaming.swift` e o `summon` do laço (`namesTaken()`), `Tests/CollieDaemonKitTests/LaneIntegrationTests.swift` (espera ativa com `Task.sleep(.milliseconds(1))`).

## Fazer
1. **MCP:** `needs` e `scope` aceitam string (vírgulas) **ou** array JSON de strings; qualquer outro tipo é **recusado** com erro claro (nunca descartado em silêncio). O esquema MCP e os testes que o enumeram seguem coerentes.
2. **Desligamento durante integração:** `cancelLoops` cancela também a integração em andamento e **não remove a faixa nem deixa o cercado em estado intermediário**: o integrador, ao ser cancelado, desfaz o merge só se a árvore está como ele a deixou (a regra da M3b.2); caso contrário deixa e o laço grava `daemonRestart`/`cancelled` com a nota. A faixa só é removida depois que a integração acabou.
3. **Nomes:** se o `summon` recusar o nome por colisão, tente o próximo sufixo (até o limite da M3.8) em vez de falhar a tentativa.
4. **Teste sem `sleep`:** troque a espera ativa de `LaneIntegrationTests` por continuação.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopLaneNitsTests.swift`
(1) `needs`/`scope` como array e como string; número/objeto recusados; (2) cancelar durante a integração: a faixa não é removida antes do fim e a árvore não fica no meio do merge; (3) colisão de nome no `summon` resolve com sufixo; (4) o teste de integração passa sem `sleep`. Suítes anteriores verdes.
