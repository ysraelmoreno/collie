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
