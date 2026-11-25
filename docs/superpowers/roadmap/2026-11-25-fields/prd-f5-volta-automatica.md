# PRD F5: `ask --check` que passa integra o field; pronto para integrar; rebase

Plano: `README.md`. Depende do F4. Spec: "Volta", respostas 4, 5, 9.

## Arquivos

- Modificar: `Sources/CollieDaemonKit/AskGate.swift` (árvore commitada; `field` no resultado)
- Modificar: `Sources/CollieDaemonKit/CommandRouter.swift` (ask: enfileirar o land; fim de turno: `ready`)
- Modificar: `Sources/CollieDaemonKit/FieldCommands.swift` (rebase pós-land, avisos)
- Teste: `Tests/CollieDaemonKitTests/FieldAutoLandTests.swift`, `Tests/CollieDaemonKitTests/AskCheckTests.swift`

## Interfaces

Consome: `landField` (F3), `TerminalRecord.field` (F4), `askGated` (C1).

- `AskCheckReport` ganha `field: FieldNote?` com `FieldNote { land: "queued" | "skipped", reason: String? }`.

Regras:
- `ask --check` a um agente com field: check passou e a árvore do field tem rastreado modificado ou não rastreado novo
  (sem ignorados) → **reprova a tentativa** com `O check passou, mas há mudanças sem commit no field: commite antes de
  encerrar.` (conta como tentativa).
- Check passou com árvore limpa → o ask termina já (`field.land = "queued"`); `landField` roda num `Task`; resultado ao
  Pastor por aviso: `[collie] field <nome> integrado em <sha8>` ou `[collie] field <nome> não integrou: <motivo>;
  patch: <caminho>`.
- Fim de turno de um agente em field `working` com commits novos desde `base` e sem ask com check em curso → `ready` e um
  aviso único ao Pastor: `[collie] field <nome> pronto para integrar: collie field land <nome>`.
- Depois de `landed`: rebase do branch do field no HEAD novo do cercado, só com o agente fora de turno e a árvore do field
  limpa; senão `behind` e nova tentativa no próximo fim de turno; `base` atualizada.

## Passos

- [ ] **Teste vermelho** em `FieldAutoLandTests`: `passedCheckQueuesLand`; `dirtyTreeFailsTry`;
  `failedCheckNoLand`; `readyNoticeOnce`; `rebaseAfterLand`; `rebaseWaitsWhenBusy` (`behind`); `landNoticeReachesShepherd`.
  Em `AskCheckTests`: `fieldNoteInReport`.
- [ ] Implementar. Check. Portão.
- [ ] Commit `feat(fields): a passing ask --check lands the field`.

## Check

```
swift test --disable-sandbox --filter FieldAutoLandTests && swift test --disable-sandbox --filter AskCheckTests
```
