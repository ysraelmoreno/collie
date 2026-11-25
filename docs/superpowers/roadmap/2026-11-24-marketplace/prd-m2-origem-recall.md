# PRD M2: origem da instalação e versão recolhida bloqueada

Plano: `README.md` desta pasta. Depende do M1 (`PluginCatalog.Recall`). Spec: "No app" (Recolhida, decidido pelo dono) e "Decisões minhas" 7.

## Arquivos

- Modificar: `Sources/CollieCore/PluginManifest.swift` (`InstalledPlugin`, ~linha 411)
- Modificar: `Sources/CollieDaemonKit/Plugins/PluginStore.swift` (`install`, `setEnabled`, `verify`/carga)
- Teste: `Tests/CollieDaemonKitTests/PluginStoreTests.swift`

## Interfaces (produz)

```swift
// InstalledPlugin: campos novos, opcionais (installed.json antigo carrega)
public enum Source: String, Codable, Sendable { case catalog, folder }
public var source: Source?                 // nil = folder (instalações de antes)
public var recalled: PluginCatalog.Recall? // M1; nil = não recolhido

// PluginStore
func install(from: URL, expect: (id: String, version: String)?, replace: Bool, source: InstalledPlugin.Source = .folder) throws(ProtocolError) -> InstalledPlugin
func applyRecalls(_ recall: (_ treeSha256: String) -> PluginCatalog.Recall?) throws(ProtocolError) -> [String]  // ids que mudaram
```

Regras:
- `applyRecalls`: para cada instalado cujo `sha256` (o hash da árvore) tem recall, grava `recalled`, `enabled = false`
  e devolve o id. Vale para qualquer `source` (recall casa por hash). Um instalado que deixou de ter recall no catálogo
  **não** é destravado (só reinstalar limpa).
- `setEnabled(id, true)` num recolhido → `ProtocolError(.conflict, "versão recolhida: <motivo>. Atualize ou remova.")`.
- `install` de outra versão do mesmo id limpa `recalled`; reinstalar a mesma árvore recolhida → recusa com a mesma
  mensagem.
- A carga (`loaded()`) nunca carrega um recolhido.

## Passos

- [ ] **Teste vermelho** em `PluginStoreTests`: `recallDisablesAndBlocks` (instala, `applyRecalls` com o hash → desligado,
  `setEnabled(true)` lança `.conflict` com o motivo, `loaded()` não tem o id); `recallMatchesFolderInstall`
  (`source: .folder`, mesmo hash → recolhido); `newVersionClearsRecall`; `sameTreeReinstallRefused`;
  `oldInstalledJsonLoads` (JSON sem `source`/`recalled` → `source == nil`, `recalled == nil`);
  `sourceIsSaved` (`install(…, source: .catalog)` → relido do disco com `.catalog`).
- [ ] Rodar `--filter PluginStoreTests` → falha.
- [ ] Implementar; `PluginCatalog.Recall` vem do M1, que já está commitado (M2 começa depois dele).
- [ ] Rodar → passa. Portão comum.
- [ ] Commit `feat(plugins): installed plug-ins keep their source and a recalled version stays off`.

## Check

```
swift test --disable-sandbox --filter PluginStoreTests && swift test --disable-sandbox --filter PluginManifestTests
```
