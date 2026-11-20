# M1.4 Fases da tentativa como máquina de estados

Leia primeiro o `README.md` desta pasta. Depende de M1.1, M1.2 e M1.3. Esta é a tarefa de maior risco da onda: se não couber com segurança, **deixe o laço exatamente como estava** (a tarefa será adiada) em vez de entregar algo que muda comportamento. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`attempt()` inteiro), `AttemptDecision.swift` (M1.3).

## Fazer

1. Novo `Sources/CollieDaemonKit/Work/AttemptMachine.swift`: `enum AttemptMachine` com `Phase` (`summoning, turn, waitingCommit, checking, gating, deciding, finished`), `Event`, `Effect`, e a função **pura** `reduce(_ s: State, _ e: Event) -> (State, [Effect])`.
   - `Event`, de fatos observáveis (nunca da fala do agente): `started`, `summoned(UUID)`, `summonFailed(String)`, `turnEnded(source: hook|idle)`, `turnTimedOut`, `turnFailed(String)`, `commitSeen`, `waitExpired`, `cancelled`, `workClosed`, `starterGone`, `checkDone(status: Int32?, broken: String?)`, `gateDone(String?)`, `gateSkipped`, `settled(moved: Bool)`, `blocked(String?)`, `decided(Outcome)`.
   - `Effect`: `summon`, `ask`, `waitForCommit`, `dismiss`, `runCheck`, `runGate`, `settle(reset:)`, `measureFacts`, `discard`, `markDone`, `markOpenOrDeferred`, `note(String)`, `journal(LoopEvent.Kind, detail)`, `stopLoop(Stop)`.
   - `State`: a fase e o que a tentativa já sabe (`before`, `judged`, `n`, flags). Imutável, `Equatable`.
2. `attempt()` vira um **interpretador**: em laço, executa o `Effect` pedido (os mesmos chamados de `host`/`store`/git de hoje, na mesma ordem) e devolve o `Event` resultante a `reduce`, até `finished`. A decisão pós-turno continua em `AttemptDecision.decide` (M1.3), chamada pelo efeito `measureFacts`/`decided`.
3. A ordem de efeitos e as condições (o portão só roda quando o check passou, há commit, a árvore está limpa e nada moveu o HEAD; `tampered` antes do portão; reset só sem `dirty` e sem `blocked`; o cancelamento sem veredito e sem desconto; trabalho fechado/Pastor sumido sem veredito) são **as de hoje**, tal qual o comentário de cada trecho.
4. `Phase` já é gravada em `loop.phase` (`agent/check/gate`); continue gravando exatamente isso (não renomeie o que o app e o `work status` leem).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/AttemptMachineTests.swift`

Tabela de transições **sem host, sem git, sem tempo**: cada linha é (estado, evento) → (estado, efeitos): o caminho feliz completo (`started → summon → ask → turnEnded → waitForCommit → commitSeen → measureFacts → runCheck → checkDone(0) → settle → runGate → gateDone(nil) → settle → decide → markDone`), sem gate; check que falha; check com timeout; `turnTimedOut` (não é falha por si, segue para o check); `turnFailed`; `summonFailed`; `cancelled` em cada fase (sem veredito); `workClosed`/`starterGone` em cada fase; `blocked` depois do check; o portão que não roda. Toda a `WorkLoopTests` (e as da M1.1, M1.2 e M1.3) passam **sem alteração de expectativa**.
