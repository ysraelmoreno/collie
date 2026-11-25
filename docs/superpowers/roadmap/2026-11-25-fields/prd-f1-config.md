# PRD F1: `collie-work.json` ganha `fields`

Plano: `README.md`. Depende do F0 (se o F0 decidiu que `warm` sai, este PRD não tem `warm`). Spec: "Aquecimento".

## Arquivos

- Modificar: `Sources/CollieCore/ProjectWorkConfig.swift`
- Teste: `Tests/CollieCoreTests/ProjectWorkConfigTests.swift`

## Interfaces (produz)

```swift
public struct FieldsConfig: Sendable, Equatable {
    public var `default`: Bool        // false
    public var warm: [String]         // []
    public var max: Int               // 4
    public static let maxRange = 1...8
}
public var fields: FieldsConfig?      // em ProjectWorkConfig; nil = chave ausente
// ConfigError novos: .fieldsMax(Int), .badWarmPath(String)
```

Regras: `fields` precisa ser objeto; `default` bool; `max` inteiro em 1...8; `warm` lista de strings, cada uma relativa
(sem `/` inicial), sem componente `..`, sem caractere de controle, até 10 itens, até 200 caracteres. Chave desconhecida
dentro de `fields` → aviso (como no topo).

## Passos

- [ ] **Teste vermelho** em `ProjectWorkConfigTests`: `fieldsParsed` (`{"version":1,"fields":{"default":true,"warm":[".build"],"max":2}}`);
  `fieldsAbsentIsNil`; `fieldsMaxOutOfRange` (0 e 9 → `.fieldsMax`); `warmRefusesTraversal` (`"../x"`, `"/abs"`,
  `"a/../b"` → `.badWarmPath`); `fieldsUnknownKeyWarns`.
- [ ] Implementar. Check. Portão (`scripts/ci/lint.sh && scripts/ci/check-architecture.sh`).
- [ ] Commit `feat(config): fields in collie-work.json`.

## Check

```
swift test --disable-sandbox --filter ProjectWorkConfigTests
```
