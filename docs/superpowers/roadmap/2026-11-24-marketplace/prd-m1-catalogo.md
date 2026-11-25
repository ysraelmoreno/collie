# PRD M1: `PluginCatalog` (formato, assinatura, ordem, validade)

Plano: `README.md` desta pasta. Spec: seção "Catálogo".

## Arquivos

- Criar: `Sources/CollieCore/PluginCatalog.swift`
- Teste: `Tests/CollieCoreTests/PluginCatalogTests.swift`

## Interfaces (produz)

```swift
public struct PluginCatalog: Codable, Sendable, Equatable {
    public struct Version: Codable, Sendable, Equatable {
        public var version: String, url: URL, sha256: String, size: Int64, treeSha256: String
        public var permissions: [String: JSONValue]?       // mesmo tipo de PluginManifest.permissions
        public var hooks: [String]?, helperTeamId: String?
        public var recalled: Recall?
    }
    public struct Recall: Codable, Sendable, Equatable { public var reason: String, at: Date }
    public struct Item: Codable, Sendable, Equatable {
        public var id: String, name: String, publisher: String, summary: String
        public var kind: Kind, minCollie: String, versions: [Version]
    }
    public enum Kind: String, Codable, Sendable { case panel, agent, engine }
    public struct Publisher: Codable, Sendable, Equatable { public var id: String, name: String, reviewedBy: String }
    public var format: Int, generatedAt: Date, sequence: Int
    public var plugins: [Item], publishers: [Publisher]

    public static let publicKeys: [String]           // base64 da chave pública crua (32 bytes); o dono cola a real
    public static let staleAfter: TimeInterval = 30 * 24 * 3600

    /// Confere assinatura (qualquer chave de `keys`), formato e coerência. `lastSequence`: o do último aceito.
    public static func accept(_ data: Data, signature: Data, keys: [String] = publicKeys,
                              lastSequence: Int?) throws(ProtocolError) -> PluginCatalog
    public func isStale(now: Date) -> Bool          // generatedAt + staleAfter < now; generatedAt no futuro: não stale
    public func recall(forTree treeSha256: String) -> Recall?   // qualquer item/versão com esse treeSha256 recolhido
    public func latest(_ id: String, collie: String) -> Version? // maior versão não recolhida com minCollie ≤ collie

    /// Para o CI (M4): assina com a chave privada crua (32 bytes, base64).
    public static func sign(_ data: Data, privateKey: String) throws(ProtocolError) -> Data
}
```

Datas ISO 8601. `format` diferente de `1` → recusado. `sequence` < `lastSequence` → recusado (igual é aceito: mesmo
catálogo baixado de novo). Item sem versão, `id` repetido, `sha256`/`treeSha256` que não são 64 hex, `url` que não é
`https://github.com/ysraelmoreno/collie/releases/download/plugin-…`, `publisher` que não está em `publishers` →
recusa do catálogo inteiro, com o motivo na mensagem.

## Passos

- [ ] **Teste vermelho** em `PluginCatalogTests` (par de chaves gerado no teste com `Curve25519.Signing.PrivateKey()`):
  - `acceptsSigned`: catálogo de exemplo do spec assinado → aceito, `plugins[0].id == "vizinho"`.
  - `refusesWrongKey`, `refusesTamperedByte` (um byte trocado após assinar), `refusesFormat2`,
    `refusesOlderSequence` (`lastSequence: 43`, catálogo 42), `acceptsSameSequence`.
  - `refusesBadItem`: versão vazia; `id` repetido; sha256 com 63 hex; url de outro caminho; publisher desconhecido.
  - `staleAfter30Days`: `generatedAt` há 31 dias → `isStale == true`; há 29 → false; amanhã → false.
  - `recallByTree`: versão recolhida com tree X → `recall(forTree: X)?.reason`; tree Y → nil.
  - `latestSkipsRecalledAndNewerCollie`: 0.2.0 recolhida, 0.3.0 com `minCollie` 9.0.0 → `latest` é 0.1.0.
- [ ] Rodar: `lockf -k .collie/build.lock swift test --disable-sandbox --filter PluginCatalogTests` → falha (tipo não existe).
- [ ] Implementar em `PluginCatalog.swift`. Comparação de versões: não existe no repo; uma função `static func compare(_ a: String, _ b: String) -> ComparisonResult`
  numérica por componente (`0.10.0 > 0.9.0`), também usada pelo M3 e M5. `publicKeys` começa com uma chave de placeholder e um comentário
  `// o dono troca pela real (README, Ações do dono 3)`.
- [ ] Rodar o mesmo filtro → passa. Portão comum.
- [ ] Commit `feat(plugins): signed plugin catalog format`.

## Check

```
swift test --disable-sandbox --filter PluginCatalogTests
```
