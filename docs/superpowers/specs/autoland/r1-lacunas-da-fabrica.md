# R1: lacunas conhecidas da fábrica (v0.2.x)

Cada ponto com teste que FALHE sem a correção; sem relógio real nem sleep nos testes novos. Check: `scripts/check-autoland-loop.sh r1|r2|r3`.

## r1 — o portão não enxerga binário trocado em pasta ignorada (cartão d16ca8d3)

O agente grava `node_modules/.bin/jest` (ou `.venv/bin/<x>`) com exit 0; o portão chama `npx jest` e passa. Nem `git diff before..judged` nem `tampered` (`WorkLoop.swift`, "Ignored files stay") enxergam, porque a pasta é ignorada pelo git.

Correção: antes da tentativa o laço registra, para `node_modules/.bin` e `.venv/bin` (e `venv/bin`) do cercado, o que há nelas (nome, tamanho, data de modificação; nunca o conteúdo); depois da tentativa, se algo mudou ou apareceu e o portão ou o aceite RODA um runner dessas pastas, o resultado é recusado como "adulterado" com a mesma mensagem e o mesmo caminho de `tampered` (conta como falha da tentativa). Não bloqueia o agente de instalar dependência na 1ª tarefa de um trabalho cujo spec cita `npm install`/`pip install`: nesse caso (spec cita o comando) vale como hoje. Testes novos em `GateIgnoredBinTests`: gate que roda `node_modules/.bin/x`, agente que o regrava → recusado; sem mudança → passa; spec que cita `npm install` → passa.

## r2 — `StopGraceTests` mede o relógio real

`Tests/CollieDaemonKitTests/StopGraceTests.swift` usa `ContinuousClock.now` e espera tempo de verdade. Troque por um relógio injetado (como `ManualClock` em `CuratorQueueTests`): o código de produção recebe o relógio (se ainda não recebe, a injeção mínima, com padrão `ContinuousClock()`), o teste avança o relógio à mão. Os mesmos casos, nenhum a menos; o teste não demora o tempo da graça.

## r3 — caixa "Cercado fábrica" desabilitada sem explicação

Na folha de Novo cercado, para uma pasta que não é repositório git a caixa fica desabilitada e não diz por quê. Mostrar, ao lado, uma linha fixa em português: "Precisa de um repositório git." (só quando desabilitada por isso; quando habilitada, nada). Testes em `NewPaddockFormTests`: texto presente com pasta fora do git, ausente com repositório.
