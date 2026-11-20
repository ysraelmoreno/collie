# M2.1 Toque em fim de turno prematuro

Leia `onda2.md` e `README.md`. Código: `Sources/CollieDaemonKit/Work/AttemptMachine.swift`, `WorkLoop.swift` (o interpretador de efeitos, `waitForCommit`), `LoopHost` (`ask`, `working`).

## Problema

O turno do agente termina (hook Stop ou ociosidade) sem commit novo, mas o trabalho não acabou (o agente perguntou algo que ninguém responde num laço autônomo, caiu num diálogo de permissão, passou por compactação). Hoje, com `.hook`, o laço vai direto ao check e a tentativa morre em segundos; com `.idle`, espera o commit até o fim do turno. A tentativa fica queimada por um sinal frágil.

## Fazer

1. Na máquina: quando `turnEnded(source: .hook)` chega **sem commit novo** e ainda há tempo no turno (`turn` do laço) e orçamento, o próximo efeito é **`nudge`**, uma vez por tentativa: `host.ask(agent, prompt: <toque>, timeout: <o que resta do turno>)` e depois o mesmo `waitForCommit` de hoje. Um segundo fim de turno sem commit segue para o check como hoje. `.idle` não muda.
2. Texto do toque (pt-BR, constante em `WorkLoop`): "Você encerrou o turno sem fazer commit. Ninguém vai responder perguntas neste laço: decida sozinho. Faça commit do que escreveu (ou diga em uma linha o que impede) e encerre."
3. O toque é registrado no diário (`LoopEvent.Kind.nudged`, detail: a fonte do fim de turno) e conta como parte da mesma tentativa (não gasta `--max` nem `--tries`).
4. Não toca quando o agente já fez commit (nada a pedir), quando o turno estourou o timeout, quando o `ask` falhou, nem quando o laço foi cancelado/parado.
5. O `Kind` novo precisa decodificar de forma tolerante nos leitores antigos (veja a regra do `onda2.md`).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopNudgeTests.swift`

Tabela do `AttemptMachine`: `turnEnded(.hook)` sem commit gera `nudge` uma vez; depois do toque, `turnEnded(.hook)` outra vez vai para o check; `.hook` com commit não toca; `.idle` não toca; turno estourado não toca; cancelamento durante o toque. Com o host falso: um agente que só faz commit depois do toque passa na 1ª tentativa e o diário tem `nudged`; um que ignora o toque falha a tentativa como hoje, com "no new commit"; o prompt do toque é o da constante.
