# PRD M4: publicar plug-ins e o catálogo (CLI + CI)

Plano: `README.md` desta pasta. Depende do M1 (`PluginCatalog.sign`, formato). Spec: "Fase 1", "Releases".

## Arquivos

- Modificar: `Sources/collie/CLI.swift` (três subcomandos locais, sem daemon)
- Criar: `scripts/ci/plugin-catalog.sh`, `scripts/ci/test-plugin-catalog.sh`
- Criar: `.github/workflows/plugins-release.yml`
- Teste: `scripts/ci/test-plugin-catalog.sh` (offline, no molde de `test-update-manifest.sh`)

## Interfaces (produz)

- `collie plugin tree-hash <pasta>` → imprime o `PluginStore.treeHash` da pasta (mesmos `scan` e limites); exit 1 com o
  motivo se a pasta não passaria na instalação.
- `collie plugin catalog-keygen --out <arquivo>` → grava a chave privada crua base64 (0600) e imprime a pública.
- `collie plugin catalog-sign <plugins.json> --key-env PLUGIN_CATALOG_KEY` → grava `<plugins.json>.sig`
  (`PluginCatalog.sign`); a chave nunca em argv.
- `collie plugin catalog-verify <plugins.json> --public <base64>` → `PluginCatalog.accept` com essa chave; exit 0/1 com o
  motivo (usado pelo teste e pelo workflow antes de subir).
- `scripts/ci/plugin-catalog.sh <catalogo-atual.json|-> <id> <versão> <pacote.tar.gz> <pasta-montada> <out.json>`:
  acrescenta (ou troca) a versão no item, `sha256`/`size` do pacote, `treeSha256` via `collie plugin tree-hash`,
  `permissions`/`hooks` do manifesto, `helperTeamId` do `codesign -dv` do `bin/*` (se houver), `sequence + 1`,
  `generatedAt` agora. Recolher: `plugin-catalog.sh --recall <id> <versão> "<motivo>"`.

## Workflow `plugins-release.yml`

- Gatilho: tag `plugin-<id>-v<versão>`; `workflow_dispatch` com `recall`.
- Monta a pasta: `Examples/plugins/<id>`; para `vizinho`, `swift build -c release --product collie-vizinho` e copia
  para `bin/vizinho`.
- Assina `bin/*` com o time e `--identifier dev.collie.plugin.<id>` (mesmos passos de `release.sh`/`figcraft.yml`),
  **depois** calcula `tree-hash`.
- `tar -czf <id>-<versão>.tar.gz -C <pai> <pasta>`; `gh release create plugin-<id>-v<versão> … --prerelease
  --latest=false`.
- Baixa o `plugins.json` atual da release `plugins-catalog` (ou começa vazio), roda `plugin-catalog.sh`, assina com
  `catalog-sign` (segredo `PLUGIN_CATALOG_KEY`), sobe os dois com `gh release upload plugins-catalog --clobber`
  (release criada uma vez `--prerelease --latest=false`).

## Passos

- [ ] **Teste vermelho** `scripts/ci/test-plugin-catalog.sh`: com uma pasta de plug-in de exemplo e uma chave gerada
  por `catalog-keygen` num tmp: o JSON gerado tem `sequence` = anterior + 1, `treeSha256` igual a `tree-hash`, o `.sig`
  passa em `collie plugin catalog-verify` com a pública impressa pelo `catalog-keygen`; `--recall` preenche `recalled.reason`; pasta com link →
  `tree-hash` sai com 1.
- [ ] Rodar → falha.
- [ ] Implementar os subcomandos, o script e o workflow.
- [ ] Rodar → passa; `actionlint` no workflow se estiver instalado. Portão comum.
- [ ] Commit `ci(plugins): publish plug-in packages and the signed catalog`.

## Check

```
scripts/ci/test-plugin-catalog.sh
```
