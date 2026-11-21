# M5.2 Stop hook: pedir memória só quando faz sentido

Leia `onda5-economia-de-tokens.md`. Código: `Sources/CollieDaemonKit/Memory/MemoryCapture.swift` (`stopReason`, `hasNewWork` ~25, a decisão ~80 `state.saved`), `Sources/collie/HookCommands.swift` e `MemoryHookClient.swift` (o hook `claude-stop`), `Sources/CollieCore/Work.swift` (`capturedAt`, `capturedCommit`).

## Problema
O Stop hook devolve "Antes de encerrar: registre decisões e armadilhas…" a cada turno em que há commit novo, inclusive os feitos pelo próprio laço, o que obriga um turno extra do Pastor (~46 mil de índice) quase sempre só para responder "nada a registrar".

## Fazer
1. **Nunca pedir** enquanto há **laço rodando** no trabalho do terminal (os commits são do laço, e `memory save` ainda derrubaria a tentativa).
2. **No máximo um pedido a cada 20 min** por terminal (relógio injetável; guardar o instante do último pedido junto de `capturedAt`).
3. O pedido só acontece se há **trabalho novo de verdade**: tarefa feita desde o último pedido, ou commit que **não** é de uma tentativa do laço (commits do laço entram no resumo do fim do laço, não no Stop hook). Quando o laço termina, **um** pedido sai no próximo Stop.
4. A mensagem do pedido continua igual. Erro ou campo ausente: **não pede** (nunca bloqueia o encerramento por falha do daemon).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/StopHookThrottleTests.swift`
Tabela: laço rodando ⇒ não pede; 2 pedidos em 5 min ⇒ só o primeiro; passados 20 min ⇒ pede de novo; commit do laço ⇒ não conta; commit do dono ⇒ conta; laço terminou ⇒ um pedido; sem trabalho ⇒ não pede; estado ausente ⇒ não pede. Os testes de `MemoryCapture` seguem verdes.
