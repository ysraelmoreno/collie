# PRD F1: `collie-work.json` ganha `fields`

Plano: `README.md`. F0 decidiu: `warm` sai (REPORT `docs/superpowers/spikes/2026-11-25-field-warm/`). Spec: "Aquecimento" (sem `warm`).

## Arquivos

- Modificar: `Sources/CollieCore/ProjectWorkConfig.swift`
- Teste: `Tests/CollieCoreTests/ProjectWorkConfigTests.swift`

## Interfaces (produz)

```swift
public struct FieldsConfig: Sendable, Equatable {
    public var `default`: Bool        // false
    public var max: Int               // 4
    public static let maxRange = 1...8
}
public var fields: FieldsConfig?      // em ProjectWorkConfig; nil = chave ausente
// ConfigError novo: .fieldsMax(Int)
```

Regras: `fields` precisa ser objeto; `default` bool; `max` inteiro em 1...8. Chave desconhecida dentro de `fields`
(inclusive `warm`) → aviso (como no topo).

## Passos

- [ ] **Teste vermelho** em `ProjectWorkConfigTests`: `fieldsParsed` (`{"version":1,"fields":{"default":true,"max":2}}`);
  `fieldsAbsentIsNil`; `fieldsMaxOutOfRange` (0 e 9 → `.fieldsMax`); `fieldsUnknownKeyWarns` (`"warm":[".build"]` → aviso).
- [ ] Implementar. Check. Portão (`scripts/ci/lint.sh && scripts/ci/check-architecture.sh`).
- [ ] Commit `feat(config): fields in collie-work.json`.

## Check

```
swift test --disable-sandbox --filter ProjectWorkConfigTests
```
