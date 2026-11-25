# PRD M3: daemon baixa, confere e instala do catálogo

Plano: `README.md` desta pasta. Depende de M1 (`PluginCatalog`) e M2 (`source`, `applyRecalls`). Spec: "Catálogo",
"Decisões minhas" 1, 2, 6, 7, 8.

## Arquivos

- Criar: `Sources/CollieDaemonKit/Plugins/PluginCatalogService.swift` (o catálogo guardado, baixar, conferir, instalar)
- Modificar: `Sources/CollieDaemonKit/Android/AndroidDownload.swift` (`allowed`: os dois caminhos do README)
- Modificar: `Sources/CollieDaemonKit/PluginAdminCommands.swift` (comandos novos), `Sources/CollieProtocol/Commands.swift`
- Modificar: `docs/plugins/api-v1.md` (seção "Catálogo"), `docs/referencia.md` (entrada curta)
- Teste: `Tests/CollieDaemonKitTests/PluginCatalogServiceTests.swift`

## Interfaces

Consome: `PluginCatalog.accept/isStale/recall/latest/compare` (M1); `PluginStore.install(…, source:)`,
`applyRecalls` (M2); `AndroidDownload.fetch(_:to:limit:headers:progress:)` e `verify(_:sha256:)`;
`FigcraftInstaller.scan(_:)` (recusa link e arquivo especial); `CodeSignature.signedByTeam(_:identifier:teamId:)`.

Produz (comandos de admin, só app/CLI fora de terminal):

| Comando | Args | Resposta |
|---|---|---|
| `plugin.catalog` | `refresh: Bool` | `{state: "ok"\|"stale"\|"unavailable", reason?, generatedAt, items: [{id, name, publisher, publisherName, summary, kind, latest: {version, size, permissions, hooks}, installed?: {version, source}, update: Bool, recalled?: {reason}}]}` |
| `plugin.install-catalog` | `id`, `version` | a linha do plug-in, como `plugin.install` |

```swift
actor PluginCatalogService {
    init(root: URL, store: PluginStore, fetch: Fetch = .live, now: @escaping @Sendable () -> Date = Date.init)
    func current(refresh: Bool) async -> (catalog: PluginCatalog?, state: State, reason: String?)
    func install(id: String, version: String) async throws(ProtocolError) -> InstalledPlugin
    func dailyRefresh() async          // chamado pelo daemon 1×/dia e na partida; aplica recalls
}
```

`Fetch` é injetável (teste sem rede): `catalog() async throws -> (Data, Data)` e `package(URL, to: URL, limit: Int64)`.

Regras:
- Guardar o último aceito em `<root>/plugins/catalog.json` + `catalog.json.sig`, 0600. Partida sem rede: usa o
  guardado (recall vale, decisão 8). Catálogo recusado: o guardado continua, `state: "unavailable"` com o motivo.
- `install`: um por vez por id (`já instalando <id>` para o segundo); staging `0700` em `<root>/plugins/.staging-*`,
  apagado em qualquer saída; `fetch` com `limit = size`; `verify(sha256)`; `tar -xzf` para o staging; `scan`; nenhum
  caminho fora do staging (`..`, absoluto); `PluginStore.scan` + `treeHash` == `treeSha256`; helper com
  `helperTeamId` → `signedByTeam(bin, identifier: "dev.collie.plugin.<id>", teamId: helperTeamId)` obrigatório; então `store.install(from: staging/<pasta>, expect: (id, version),
  replace: true, source: .catalog)`.
- Atualização sem permissão nova não pede nada ao daemon além de `plugin.install-catalog` (a confirmação é do app, M5).
- `dailyRefresh`: `accept` com `lastSequence` do guardado; `applyRecalls { catalog.recall(forTree: $0) }`; publica
  `plugins` de novo se algum mudou.

## Passos

- [ ] **Teste vermelho** em `PluginCatalogServiceTests` (Fetch falso, catálogo assinado com chave do teste via
  `keys:`): `installsFromCatalog` (source `.catalog`, hash igual); `refusesShaMismatch`; `refusesTreeMismatch`;
  `refusesTraversal` (tar com `../evil` e com link → recusado, nada em `plugins/`); `interruptedDownloadLeavesNothing`
  (Fetch lança no meio → staging apagado, instalado anterior intacto); `secondInstallRefused` (duas chamadas
  concorrentes → uma recusa "já instalando"); `offlineUsesStored` (Fetch lança → `state` vem do guardado e recall do
  guardado é aplicado); `refusedCatalogKeepsStored`; `dailyRefreshRecalls` (versão recolhida → `enabled == false`,
  `recalled` preenchido); `staleState`; `helperNeedsTeam` (`helperTeamId` e helper sem assinatura → recusado).
- [ ] Rodar `--filter PluginCatalogServiceTests` → falha.
- [ ] Implementar; ligar `plugin.catalog`/`plugin.install-catalog` em `PluginAdminCommands`; `dailyRefresh` na partida
  do daemon e num `Task` diário (o mesmo molde da checagem do atualizador, se houver; senão `Task.sleep(86_400 s)`).
- [ ] Teste de `AndroidDownload.allowed` para os dois prefixos novos e um vizinho errado (`/plugins-catalogX/`).
- [ ] Docs. Rodar o check → passa. Portão comum.
- [ ] Commit `feat(plugins): install and update plug-ins from the signed catalog`.

## Check

```
swift test --disable-sandbox --filter PluginCatalogServiceTests && swift test --disable-sandbox --filter PluginStoreTests \
  && swift test --disable-sandbox --filter AndroidDownloadTests
```

(Se os testes de `allowed` estiverem noutra suíte, use a dela no lugar de `AndroidDownloadTests`.)
