# PRD F2: `LaneWorktree` com formato de field

Plano: `README.md`. Depende do F0. Spec: "Respostas à revisão" 1, "Aquecimento".

## Arquivos

- Modificar: `Sources/CollieDaemonKit/Work/LaneWorktree.swift`
- Teste: `Tests/CollieDaemonKitTests/LaneWorktreeTests.swift`, `Tests/CollieDaemonKitTests/LaneSweepScopeTests.swift`

## Interfaces (produz)

```swift
extension Lane { var isField: Bool }                       // path com last component "field-…" e branch "collie/field/…"
enum LaneWorktree {
    static func validate(field name: String) throws(ProtocolError)   // ^[a-z0-9][a-z0-9-]{0,39}$
    static func createField(repoRoot: URL, base: String, name: String, owner: UUID, warm: [String], from source: URL,
                            host: some LoopHost) async throws(ProtocolError) -> Lane
    static func field(named name: String, repoRoot: URL, host: some LoopHost) async -> Lane?
}
```

Regras:
- `createField`: mesma sequência de `createLocked` (serial por repo pelo `LaneGitQueue`, recusa caminho/branch
  existente, `git worktree add -b collie/field/<nome> <path> <base>`), marcador `field <owner uuid>`.
- Aquecimento (só se o F0 decidiu que vale): para cada item de `warm` que existe em `source`, `clonefile` (`CLONE_NOFOLLOW`)
  para o mesmo caminho relativo no field; item ausente é pulado; falha de clone → field criado sem ele, com uma linha
  de aviso no retorno (não falha a criação). Se o F0 decidiu "caminho fixo", siga a decisão do REPORT no lugar do clone.
- `ownsPath`, `isLane` (ou um `isLaneOrField`), `adminDir`, `isMarked` aceitam o formato de field.
- `orphans` e `sweep` **ignoram** qualquer `field-` (teste).
- `remove(_:)` de um field **não** roda `branch -D` (o branch fica; spec "Dispensa").

## Passos

- [ ] **Teste vermelho**: `fieldNameValidation` (`"ok-1"` passa; `"A"`, `"a/b"`, `".."`, `"a b"`, 41 chars falham);
  `createFieldMakesBranchAndMarker`; `createFieldRefusesExisting`; `warmClonesBuild` (pasta `.build/x` na fonte → existe
  no field; item ausente pulado); `sweepSkipsFields` (em `LaneSweepScopeTests`: um `field-` sem work conhecido fica);
  `removeFieldKeepsBranch`.
- [ ] Implementar. Check. Portão.
- [ ] Commit `feat(fields): lane worktree in the field shape`.

## Check

```
swift test --disable-sandbox --filter LaneWorktreeTests && swift test --disable-sandbox --filter LaneSweepScopeTests
```
