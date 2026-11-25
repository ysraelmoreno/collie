# PRD M5: app — aba Descobrir, atualizar, recolhido bloqueado

Plano: `README.md` desta pasta. Depende do M3 (`plugin.catalog`, `plugin.install-catalog`). Spec: "No app". Prévia
aprovada: `docs/pages/plugin-marketplace/index.html` (estados 1 a 4; o 5 é da fase 2).

## Arquivos

- Modificar: `Sources/CollieApp/PluginsPreferences.swift` (abas Instalados/Descobrir), `Sources/CollieClient/DaemonClient.swift`
  (dois métodos)
- Criar: `Sources/CollieApp/PluginCatalogModel.swift` (puro: linhas, filtro, estado do botão)
- Teste: `Tests/CollieAppTests/PluginCatalogModelTests.swift`, `Tests/CollieAppTests/PluginInstallPromptTests.swift`

## Interfaces

Consome: `plugin.catalog`, `plugin.install-catalog` (M3); `PluginInstallPrompt` e `newPermissions` (existentes).

```swift
// DaemonClient
public func pluginCatalog(refresh: Bool) async throws -> PluginCatalogView   // decodifica a resposta do M3
public func installFromCatalog(id: String, version: String) async throws

// PluginCatalogModel
enum CatalogFilter: CaseIterable { case all, panel, agent, engine }   // "Todos", "Painéis", "Agentes", "Motores"
enum CatalogAction: Equatable { case install, installed, update(needsConfirm: Bool), recalled(reason: String), engine }
static func rows(_ v: PluginCatalogView, filter: CatalogFilter) -> [CatalogRow]
static func action(_ item: PluginCatalogView.Item) -> CatalogAction
```

Regras (do spec, decididas pelo dono):
- `update(needsConfirm:)`: `true` só se a versão nova tem linha de permissão que a instalada não tinha
  (`permissionLines`); `false` → um clique chama `installFromCatalog` direto.
- `recalled`: interruptor desligado e desabilitado, motivo na linha ("recolhido: <motivo>"), botão para a versão boa
  se `latest` existir.
- `kind == .engine`: botão leva ao instalador do motor (Desenho, para o FigCraft), não a `installFromCatalog`.
- `state == "unavailable"`: "O catálogo não carregou. Os plug-ins instalados seguem funcionando." + "Tentar de novo".
  `"stale"`: aviso "catálogo desatualizado" acima da lista.
- A confirmação de instalação do catálogo mostra "Do catálogo, publicado por <publisherName> · revisado".
- "Instalar de uma pasta…" continua (hoje "Instalar…").

## Passos

- [ ] **Teste vermelho** em `PluginCatalogModelTests`: filtro por tipo; `action` para não instalado / instalado igual /
  update sem permissão nova (`needsConfirm == false`) / update com permissão nova (`true`) / recolhido / motor.
  Em `PluginInstallPromptTests`: a linha "Do catálogo, publicado por Collie · revisado".
- [ ] Rodar → falha.
- [ ] Implementar o modelo, os dois métodos do cliente e a tela, seguindo a prévia.
- [ ] Rodar → passa. Portão comum.
- [ ] Commit `feat(app): Descobrir tab installs and updates plug-ins from the catalog`. No corpo, o que o dono confere
  no app real: os 4 estados da prévia, um clique de atualizar sem confirmação, interruptor do recolhido sem efeito.

## Check

```
swift test --disable-sandbox --filter PluginCatalogModelTests && swift test --disable-sandbox --filter PluginInstallPromptTests
```
