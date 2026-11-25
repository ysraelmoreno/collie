# PRD F2: `LaneWorktree` com formato de field

Plano: `README.md`. F0 decidiu: sem aquecimento. Spec: "Respostas à revisão" 1.

## Arquivos

- Modificar: `Sources/CollieDaemonKit/Work/LaneWorktree.swift`
- Teste: `Tests/CollieDaemonKitTests/LaneWorktreeTests.swift`, `Tests/CollieDaemonKitTests/LaneSweepScopeTests.swift`

## Interfaces (produz)

```swift
extension Lane { var isField: Bool }                       // path com last component "field-…" e branch "collie/field/…"
enum LaneWorktree {
    static func validate(field name: String) throws(ProtocolError)   // ^[a-z0-9][a-z0-9-]{0,39}$
    static func createField(repoRoot: URL, base: String, name: String, owner: UUID,
                            host: some LoopHost) async throws(ProtocolError) -> Lane
    static func field(named name: String, repoRoot: URL, host: some LoopHost) async -> Lane?
}
```

Regras:
- `createField`: mesma sequência de `createLocked` (serial por repo pelo `LaneGitQueue`, recusa caminho/branch
  existente, `git worktree add -b collie/field/<nome> <path> <base>`), marcador `field <owner uuid>`.
- Sem aquecimento: o field compila frio na primeira vez (F0: `.build` clonado falha por caminho absoluto no PCH).
- `ownsPath`, `isLane` (ou um `isLaneOrField`), `adminDir`, `isMarked` aceitam o formato de field.
- `orphans` e `sweep` **ignoram** qualquer `field-` (teste).
- `remove(_:)` de um field **não** roda `branch -D` (o branch fica; spec "Dispensa").

## Passos

- [ ] **Teste vermelho**: `fieldNameValidation` (`"ok-1"` passa; `"A"`, `"a/b"`, `".."`, `"a b"`, 41 chars falham);
  `createFieldMakesBranchAndMarker`; `createFieldRefusesExisting`; `sweepSkipsFields` (em `LaneSweepScopeTests`: um `field-` sem work conhecido fica);
  `removeFieldKeepsBranch`.
- [ ] Implementar. Check. Portão.
- [ ] Commit `feat(fields): lane worktree in the field shape`.

## Check

```
swift test --disable-sandbox --filter LaneWorktreeTests && swift test --disable-sandbox --filter LaneSweepScopeTests
```
