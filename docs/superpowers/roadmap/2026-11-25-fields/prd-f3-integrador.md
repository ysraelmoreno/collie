# PRD F3: um integrador por cercado e o land de field

Plano: `README.md`. Depende do F2 (`Lane.isField`). Spec: "Respostas à revisão" 2, 3, 6, 7.

## Arquivos

- Modificar: `Sources/CollieDaemonKit/Work/LaneIntegrator.swift` (aceitar `collie/field/`)
- Criar: `Sources/CollieDaemonKit/Work/PaddockIntegrators.swift` (registro cercado → integrador; land de field)
- Modificar: `Sources/CollieDaemonKit/Work/WorkLoopLanes.swift:47` (usar o registro)
- Modificar: `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`--parallel > 1` recusa com fields vivos)
- Teste: `Tests/CollieDaemonKitTests/FieldLandTests.swift`, `Tests/CollieDaemonKitTests/LaneIntegratorRaceTests.swift`

## Interfaces (produz)

```swift
actor PaddockIntegrators {
    func integrator(paddock: UUID, make: () -> LaneIntegrator) -> LaneIntegrator   // o mesmo por cercado
}
struct FieldLand: Sendable, Equatable {
    enum Outcome: Sendable, Equatable { case landed(sha: String), conflict(reason: String, patch: URL?), waiting(reason: String) }
}
extension CommandRouter {
    func landField(_ lane: Lane, terminal: UUID, by: UUID?) async -> FieldLand.Outcome
}
```

Regras:
- `integrate` aceita `collie/lane/` ou `collie/field/`; resto igual.
- `landField`: um por field (segundo → `waiting("já integrando")`); espera o cercado livre (árvore limpa e ninguém num
  turno, **sem contar** o Pastor que só espera um `ask` ou `work wait`); passa 10 min esperando → `waiting` com o motivo,
  e o chamador avisa o Pastor; integra com `gate` do `collie-work.json` do HEAD; conflito/portão → `conflict` com patch
  `<raiz>/fields/<nome>-<n>.patch` (`git diff <base>..<branch>`, 0600).
- `work run --parallel > 1` com algum `TerminalRecord.field` vivo no cercado → recusa "há fields vivos neste cercado:
  <nomes>". (O inverso, `summon --field` com laço em faixas, é do F4.)

## Passos

- [ ] **Teste vermelho** em `FieldLandTests` (host falso, como os `Lane*Tests`): `landsCleanField`;
  `conflictWritesPatch`; `secondLandWaits`; `waitsForBusyPaddock` (outro terminal em turno → `waiting`);
  `shepherdWaitingDoesNotBlock`; `gateFailureIsConflict`. Em `LaneIntegratorRaceTests`: `oneQueuePerPaddock` (laço e
  field no mesmo cercado usam o mesmo integrador). Em `WorkLoopCommandTests`: `parallelRefusedWithLiveFields`.
- [ ] Implementar. Check. Portão.
- [ ] Commit `feat(fields): one integrator per paddock and field landing`.

## Check

```
swift test --disable-sandbox --filter FieldLandTests && swift test --disable-sandbox --filter LaneIntegratorRaceTests \
  && swift test --disable-sandbox --filter WorkLoopCommandTests
```
