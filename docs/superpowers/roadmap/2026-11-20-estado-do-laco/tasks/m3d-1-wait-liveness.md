# M3d.1 Um `work.wait` órfão não faz o starter passar por "só esperando"

Leia `onda3d.md` e o **achado 1** de `rev-onda3c-report.md`. Código: `WorkCommands.swift` (~326-341, `ownWaitBegan` com `defer`, `work.status`, ~417 timeout), `WorkLoopCommands.swift` (~399-407, `loopAnyoneWorking`/`loopStarterWaits`), `UnixSocket.swift` (~160-174, `process`/`halt`, handler em `Task.detached`), `Sources/collie/CLI.swift` (~16).

## Problema
A contagem de "o starter só espera" mede pedidos abertos no daemon, não um cliente vivo: se o cliente do `work.wait` morre (timeout do Bash, Ctrl-C) o handler continua estacionado até 10 min e o Shepherd, que voltou a editar, continua fora do `who`. Se o wait roda em segundo plano, o selo `working` é ignorado.

## Fazer
1. Guardar o **pid do cliente** junto de cada espera aberta (o handler já recebe o `peer`); em `loopStarterWaits`, uma espera só conta se o pid **ainda existe** (`kill(pid, 0) == 0`) e o cliente não fechou o socket. Preferível se barato: manter a leitura do socket armada durante o handler para ver o EOF/HUP e **cancelar** o handler (e desfazer o registro). Escolha a mais simples que não quebre o `work.wait` normal e diga no commit qual.
2. Se o starter **ficou `working` depois de iniciar** a espera (selo `working` posterior ao início), ele **volta a contar**: uma espera só vale como "parado" enquanto o terminal não tem turno ativo além dela.
3. Sem `sleep`; relógio injetável onde houver tempo.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/StarterWaitLivenessTests.swift`
Com o daemon real de teste (`withDaemon`): um `work.wait` cujo cliente fecha o socket deixa de contar (o handler é cancelado e o registro desfeito); um pid inexistente não conta; selo `working` posterior ao início da espera faz contar; um `work.wait` vivo e quieto continua não contando (regressão da M3c.2); desconexão limpa do contador (sem vazamento). `LaneIntegratorWaitTests` segue verde.
