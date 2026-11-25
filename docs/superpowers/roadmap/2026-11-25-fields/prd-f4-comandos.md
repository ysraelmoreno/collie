# PRD F4: `summon --field`, `field list/land/drop`, dispensa, orientação

Plano: `README.md`. Depende de F1, F2, F3. Spec: "Comandos", "Registro", "Dispensa", "Orientação", respostas 3, 8, 10, 11.

## Arquivos

- Modificar: `Sources/CollieCore/Workspace.swift` (`TerminalRecord.field: FieldRef?`)
- Modificar: `Sources/CollieDaemonKit/ShepherdCommands.swift` (`summon --field/--no-field`; `dismiss`)
- Criar: `Sources/CollieDaemonKit/FieldCommands.swift` (`field.list`, `field.land`, `field.drop`)
- Modificar: `Sources/CollieProtocol/Commands.swift`, `Sources/CollieDaemonKit/CollieOrientation.swift`,
  `docs/referencia.md`
- Teste: `Tests/CollieDaemonKitTests/FieldCommandsTests.swift`, `Tests/CollieDaemonKitTests/CollieOrientationTests.swift`,
  `Tests/CollieCoreTests/WorkspaceTests.swift`

## Interfaces

Consome: `FieldsConfig` (F1), `LaneWorktree.createField/field(named:)/remove` (F2), `landField` (F3).

```swift
public struct FieldRef: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case working, ready, landing, landed, conflict, behind }
    public var name: String, branch: String, base: String, path: String, state: State
}
// TerminalRecord.field: FieldRef?   (opcional; decodifica workspace antigo)
```

Comandos (Pastor que convocou, ou o app):

| Comando | Resultado |
|---|---|
| `summon <nome> --field` | cria o field (`LaneWorktree.createField`, `max` do F1), lança o agente com `cwd`/projeto = field, `rec.field` gravado |
| `summon <nome> --no-field` | ignora `fields.default` |
| `field list` | `[{name, agent, branch, base, commits, state}]` dos fields do cercado |
| `field land <nome>` | `landField` (F3); resposta com o `Outcome` |
| `field drop <nome> [--keep-branch]` | patch WIP + remove a worktree; sem `--keep-branch`, guarda `<nome>-<n>.patch` e apaga o branch |

Regras:
- `--field` sem sandbox, para shell, ou com `--paddock`/`--cwd` → recusa. `max` atingido → recusa com o número. Laço em
  faixas rodando no cercado → recusa.
- `fields.default` lido de `WorkConfigFile.read(base:)` do HEAD do cercado.
- `dismiss` de um agente com field não `landed`: grava `<raiz>/fields/<nome>-wip.patch` (rastreado e não rastreado, sem
  ignorados), `LaneWorktree.remove` (sem `branch -D`), avisa o Pastor com o branch e o patch. Cascata do B1 faz o mesmo
  por field.
- Orientação de um agente em field (dentro de 1500): `- Field "<nome>" (branch collie/field/<nome>): commite aqui; o
  Pastor integra.` O Pastor aprende `summon --field` e `field land|drop` só se couber (a forma mais curta perde primeiro).

## Passos

- [ ] **Teste vermelho** em `FieldCommandsTests`: `summonFieldCreatesAndLaunches` (cwd = path do field, `rec.field`
  gravado); `summonWithoutFlagUnchanged`; `defaultFromHeadConfig` (`fields.default: true` commitado → field; só na
  árvore → não); `noFieldOverrides`; `maxReached`; `refusedWithLaneLoop`; `dismissKeepsBranchAndWritesWip`;
  `dropRemovesBranchUnlessKeep`; `landDelegatesToIntegrator`; `onlySummonerLands`. Em `WorkspaceTests`:
  `oldRecordWithoutField`. Em `CollieOrientationTests`: `fieldLineWithinCap`.
- [ ] Implementar. Check. Portão.
- [ ] Commit `feat(fields): summon --field and field list/land/drop`.

## Check

```
swift test --disable-sandbox --filter FieldCommandsTests && swift test --disable-sandbox --filter CollieOrientationTests \
  && swift test --disable-sandbox --filter WorkspaceTests
```
