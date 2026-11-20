# M1b.2 Custo de escrita do diário

Leia `onda1b.md` e `README.md`. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`event(...)`, `phase(...)`, os pontos onde um `phase` é seguido por um `event`), `Sources/CollieDaemonKit/Work/WorkStore.swift` (`mutate`: codifica todos os trabalhos e grava inteiro a cada `update`), `LoopCommands`/`WorkLoopCommands.swift` (onde o trabalho fecha).

## Problema

Uma tentativa que passa, com gate, grava ~16 vezes o arquivo de trabalhos inteiro (antes: ~5), cada gravação dispara o aviso ao app. O anel de 100 eventos também fica nos até 200 trabalhos fechados.

## Fazer

1. **Juntar gravações vizinhas.** Onde o motor muda `loop.phase` e logo em seguida registra um evento (`checkStarted`, `gateStarted`, a limpeza de `phase` seguida de `verdict`, `attemptStarted` junto ao primeiro `update` de início), faça **uma só** `store.update` que muda a fase e acrescenta o evento. Meta: no máximo **8** `store.update` numa tentativa que passa com gate, contando o `spent`. Um helper interno `record(_ id:, phase:, event:)` mantém o código curto. **Nenhuma decisão muda e a ordem dos eventos no diário é a de hoje.**
2. **Podar o diário ao fechar.** Quando um trabalho fecha (`closedAt` é gravado), mantenha só os **últimos 20** eventos do laço dele; o anel de 100 vale só enquanto o laço é do trabalho ativo.
3. Um teste de contagem fixa o número de gravações (com um `WorkStore` de teste que conta `update`s, ou um contador no host falso), para a regressão não voltar sem ninguém ver.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopJournalWritesTests.swift`

Contagem de `store.update` por tentativa: passa sem gate, passa com gate, falha no check, falha sem commit (cada uma com o teto esperado, de modo que um aumento futuro quebre o teste); a **ordem** dos eventos continua `attemptStarted, agentSummoned, turnEnded, commitSeen, agentDismissed, checkStarted, checkFinished, (gateStarted, gateFinished,) verdict`; um trabalho fechado com 100 eventos passa a ter 20 (os mais novos); um trabalho ativo mantém 100. `LoopJournalTests` continua verde sem mudar expectativa.
