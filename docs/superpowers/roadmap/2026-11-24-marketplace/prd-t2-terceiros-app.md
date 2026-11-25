# PRD T2 (fase 2): autor de fora no app

Plano: `README.md` desta pasta. Depende de M5 e T1. Spec: "Fase 2" (No app). Prévia: estado 5 de
`docs/pages/plugin-marketplace/index.html`.

## Arquivos

- Modificar: `Sources/CollieApp/PluginCatalogModel.swift`, `Sources/CollieApp/PluginsPreferences.swift`
  (`PluginInstallPrompt`)
- Modificar: `Sources/CollieDaemonKit/Plugins/PluginCatalogService.swift` (só se `publisherName`/`reviewedBy` ainda não
  saem no `plugin.catalog`)
- Teste: `Tests/CollieAppTests/PluginCatalogModelTests.swift`, `Tests/CollieAppTests/PluginInstallPromptTests.swift`

## Regras

- Cartão de terceiro: "<publisherName> · revisado pelo Collie" (`reviewedBy == "collie"`); do dono: "Collie · revisado".
- Confirmação de um item cujo `publisher != "collie"`: aviso fixo acima das permissões — "O autor é <publisherName>,
  não o Collie. O Collie revisou esta versão." — e, com helper, "Roda um programa assinado por <publisherName>
  (time <helperTeamId>)".
- Atualização de terceiro sem permissão nova: um clique, como do dono (a revisão foi do PR).
- Nada muda na verificação do daemon: o `helperTeamId` do item já é o do autor (T1) e o M3 confere.

## Passos

- [ ] **Teste vermelho**: rótulo do autor no modelo; aviso e linha do helper no `PluginInstallPrompt` para
  `publisher` de fora; nenhum aviso para `collie`.
- [ ] Implementar. Rodar → passa. Portão comum.
- [ ] Commit `feat(app): third-party plug-ins show their author and Collie's review`. No corpo: conferir o estado 5
  da prévia no app real.

## Check

```
swift test --disable-sandbox --filter PluginCatalogModelTests && swift test --disable-sandbox --filter PluginInstallPromptTests
```
