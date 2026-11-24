# A5: próximo trabalho da fila após o land, com tetos

Depende de A4 (`--auto-land`, `stopReason` `landed`). Só em cercado fábrica e só com `--auto-land`.

## Comportamento
Nova flag `--auto-land-max <N>` (padrão 1, no máximo 5): quantos trabalhos o laço pode integrar numa mesma execução. Depois de um `landed`, se `N` não foi atingido e o cercado tem outro trabalho APROVADO pelo dono na fila (o mesmo conceito que `work run` já usa para "tarefas e checks aprovados"), o laço ativa o próximo trabalho e segue.
Sem trabalho aprovado na fila: termina com `stopReason` `queueEmpty` (não é erro). O dono nunca aprova nada pelo laço: só trabalhos já aprovados entram.
Teto diário: `factory.guardrails.autoLandPerDay` do perfil (padrão 3); contado pelo diário de `landed` do cercado nas últimas 24 h; estourado ⇒ para com `landDailyCap` e chama o dono. O `--budget` do laço vale para a execução inteira (todos os trabalhos), não por trabalho.
Antes de cada novo trabalho, o `factory doctor` do cercado precisa seguir passando o mínimo (static e judge ≥ 1); senão `landDoctorRegressed`. Qualquer falha de A4 no trabalho seguinte para a corrente toda.

## Testes
Fila com 2 trabalhos e N=1 integra um e para (`maxReached`); N=2 integra dois; fila vazia ⇒ `queueEmpty`; teto diário; trabalho não aprovado nunca entra; doctor regredido para. Hosts falsos, sem relógio real.

Check: `scripts/check-autoland-loop.sh a5`. Commit ao final, só os arquivos da tarefa. Perfil: acrescente `autoLandPerDay` ao `FactoryProfile` com validação (inteiro 1 a 20) e atualize o modelo em `docs/fabrica/modelos/`.

Nome obrigatório da suíte (o check filtra por ela): `AutoLandTests` (arquivo novo em `Tests/CollieDaemonKitTests`).

## Segunda tentativa: o que a revisão vetou nas tentativas 1 e 2 (leia antes de começar)

Cada ponto abaixo é um achado real; cubra cada um com teste que FALHE sem a correção.

1. **Uma só regra de "terminou" (veto da `simplicidade`, tentativa 2).** `Sources/CollieApp/LoopSection.swift` (~150, `HistoryRow.init`) decide `.stopped` testando só `landed`; o motor usa `WorkLoopState.Stop.finishes` (que também conta `queueEmpty` e `maxReached` com detalhe). Use o MESMO predicado do motor na UI
   (a UI importa `CollieCore`; se `finishes` depende de `code`+`detail`, exponha-o como função pura sobre os dois campos do `HistoryEntry` e reutilize; nada de segunda lista de códigos). Teste: `maxReached` com detalhe, `queueEmpty` e `landed` dão `.complete`; `budgetSpent` dá `.stopped`.
2. **Reserva do cercado e encadeamento (veto da `motor-concorrencia`, tentativa 1).** `chainLoop` só rodava depois de `loopEnded`, que espera o aviso ao starter (até 1800 s): o próximo trabalho ficava `running` sem motor e sem reserva. Inicie o próximo trabalho ANTES do aviso ao starter (ou mande o aviso numa `Task` separada),
   mantenha a reserva do cercado em `loopPaddocks` de uma execução para a outra (sem soltar e reservar de novo) e ative `queued→running` só dentro de `chainLoop`, de modo que `running` nunca exista sem motor registrado em `workLoops`. Se `chainLoop` não conseguir iniciar, o trabalho volta a `queued` (não vira `stopped`).
3. **`work stop` vale na corrente.** Cheque `stopping` (e cancelamento) de novo logo antes de ativar o próximo trabalho e depois de cada `await` de `afterLand`; pedido de parada ⇒ devolve `.requested` sem ativar nada. Um `work stop` que chega depois de `engine.run` retornar e antes do `chainLoop` também impede o encadeamento.
4. **`queueEmpty` com N=1.** Com `--auto-land-max 1` e fila vazia, o fim é `landed` (integrou o que havia); `queueEmpty` só aparece quando o teto N ainda não foi atingido e a fila acabou. Documente isso no `--help` e nos testes.
5. **Diário:** só grave `.stopped` quando `!why.finishes`; fim de corrente (`queueEmpty`, `maxReached` com detalhe) grava o evento de fim normal.

Check: `scripts/check-autoland-loop.sh a5`. Commit ao final, só os arquivos da tarefa.
