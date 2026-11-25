# PRD T1 (fase 2): `collie plugin validate` e o repositório `collie-plugins`

Plano: `README.md` desta pasta. Depende do M4 e da fase 1 em uso. Spec: "Fase 2".

## Arquivos

Neste repositório:
- Modificar: `Sources/collie/CLI.swift` (`collie plugin validate <pasta>`)
- Teste: `Tests/CollieCoreTests/PluginManifestTests.swift` ou suíte nova `PluginValidateTests`

No repositório novo `ysraelmoreno/collie-plugins` (criado pelo dono, README "Ações do dono" 4):
- `README.md` (como submeter), `plugins/<id>/<versão>/` (a pasta) ou `plugins/<id>/<versão>.json`
  (`{"repo": "https://github.com/<autor>/<repo>", "tag": "<tag>", "path": "<pasta no repo>"}`), `publishers/<id>.json`
  (`{"id","name","contact","url"}`)
- `.github/workflows/check.yml` (em todo PR) e `.github/workflows/publish.yml` (no merge em `main`)

## Interfaces

- `collie plugin validate <pasta>` → o mesmo que a instalação recusaria (`PluginManifest.load`, `PluginStore.scan`,
  limites, sem links), mais: `permissions.network` vazio; `helper` exige `bin/<nome>` Mach-O assinado
  (`codesign -dv` com TeamIdentifier e identificador `dev.collie.plugin.<id>`) e imprime o `TeamIdentifier`. Exit 0 = ok; 1 = motivos, um por linha.
- `check.yml`: para cada pasta tocada no PR, `collie plugin validate`; o `publisher` do PR existe em `publishers/`;
  o autor do PR é o dono do `publishers/<id>.json` (primeiro PR de um autor exige o `publishers/` junto).
- `publish.yml` (só no merge, que só o dono faz): monta o pacote (da pasta ou do `repo@tag`), roda
  `scripts/ci/plugin-catalog.sh` do repositório do app (checkout do `ysraelmoreno/collie` na tag da última release),
  com `publisher` = id do autor e `helperTeamId` do autor; **rehospeda** o pacote como release
  `plugin-<id>-v<versão>` em `ysraelmoreno/collie` (`--prerelease --latest=false`) com o token de release; assina e
  sobe o catálogo como o M4. Segredos: `PLUGIN_CATALOG_KEY`, `COLLIE_RELEASE_TOKEN`.

## Passos

- [ ] **Teste vermelho** de `validate`: pasta boa → 0; com link → 1 e o motivo; `network` não vazio → 1; helper sem
  assinatura → 1.
- [ ] Implementar `validate` aqui; commit `feat(plugins): collie plugin validate`.
- [ ] Escrever os arquivos do `collie-plugins` em `docs/superpowers/roadmap/2026-11-24-marketplace/collie-plugins/`
  (o dono copia para o repositório novo; nenhum agente cria repositório nem segredo). Commit `docs: …`.
- [ ] Teste manual descrito no README do `collie-plugins`: PR de exemplo com um plug-in de painel sem helper, `check`
  verde, merge, catálogo com `sequence` + 1 e o item com `publisher` do autor.

## Check

```
swift test --disable-sandbox --filter PluginValidateTests
```
