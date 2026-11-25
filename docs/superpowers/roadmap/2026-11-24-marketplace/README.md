# Plano: marketplace de plug-ins

> **Para quem executa:** cada PRD é uma tarefa, num terminal convocado pelo Pastor, no mesmo cercado. Cada um tem o
> seu check; todos passam também pelo portão comum. Fase 2 só começa com a fase 1 em uso.

**Objetivo:** achar, instalar, atualizar e recolher plug-ins por um catálogo assinado, sem escolher pasta; depois,
aceitar plug-ins de terceiros revisados pelo dono.

**Arquitetura:** o daemon baixa e confere (`plugins.json` + Ed25519, `sequence`, sha256 do pacote, hash da árvore do
`PluginStore`, assinatura do helper) e entrega à instalação de hoje; o app só lista e pede. O CI publica pacotes e
catálogo como releases `--prerelease --latest=false` no repositório público.

**Tecnologia:** Swift 6, CryptoKit (`Curve25519.Signing`), `URLSession` pelo `AndroidDownload.fetch`, `/usr/bin/tar`,
`codesign`, GitHub Actions com `gh`.

**Spec:** `docs/superpowers/specs/2026-11-24-plugin-marketplace-design.md` (aprovado pelo dono em 2026-11-24). Leia
inteiro antes do seu PRD.

## Restrições globais

- Só o usuário instala, atualiza, liga, desliga e remove: todo comando novo é de admin (app ou CLI fora de terminal).
- Sem dependência nova. Ed25519 é `CryptoKit.Curve25519.Signing`.
- Releases `plugin-<id>-v<versão>` e `plugins-catalog` sempre `--prerelease --latest=false`.
- Download só pelo `AndroidDownload.fetch` com `allowed`; caminhos novos exatos:
  `/ysraelmoreno/collie/releases/download/plugin-` e `/ysraelmoreno/collie/releases/download/plugins-catalog/`.
- Hash da árvore = `PluginStore.treeHash` (`SHA256(rel ‖ 0 ‖ SHA256(conteúdo))` em ordem de caminho), o mesmo número
  do `installed.json`.
- Limites do pacote = os da instalação: 5 000 entradas, 64 MiB, sem links, sem arquivo especial.
- Catálogo com `generatedAt` > 30 dias: aceito para listar, marcado "desatualizado".
- Textos ao usuário em pt-BR.
- Testes só com `swift test --disable-sandbox --filter <Suite>`, dentro de `lockf -k .collie/build.lock`; nunca a suíte
  inteira. Rode o check do PRD uma vez, no fim.

## Foco de revisão

Entradas que o spec implica e que nenhum teste de tarefa cobriria sozinho (cada uma tem o teste no PRD dono):

1. **Pacote com caminho que sai da pasta** (`../x`, caminho absoluto, link no tar): recusado antes de copiar (M3).
2. **Download cortado no meio** (rede cai): nada instalado, staging apagado, o instalado anterior intacto (M3).
3. **Catálogo com `format` desconhecido ou item sem versão**: o catálogo inteiro é recusado com o motivo, o último
   aceito continua valendo (M1).
4. **Relógio do Mac adiantado/atrasado**: `generatedAt` no futuro não conta como novo para a validade; `sequence` é o
   que ordena (M1).
5. **Dois cliques em Instalar** (ou instalar e atualizar o mesmo id ao mesmo tempo): um só roda, o outro recebe
   "já instalando" (M3).

## Ações do dono (fora do código)

1. Gerar o par de chaves: `collie plugin catalog-keygen --out <arquivo>` (M4) imprime a chave pública; guardar o
   arquivo privado fora do repo.
2. Pôr a chave privada no segredo `PLUGIN_CATALOG_KEY` do repositório (e, na fase 2, do `collie-plugins`).
3. Colar a chave pública em `PluginCatalog.publicKeys` (M1) e publicar uma versão do app com ela antes do primeiro
   catálogo.
4. Fase 2: criar o repositório `ysraelmoreno/collie-plugins` e um token de escrita de release do repositório do app.

## Portão comum

```
scripts/ci/lint.sh && scripts/ci/check-architecture.sh
```

## PRDs e ondas

| Onda | PRD | O quê | Depende de |
|---|---|---|---|
| 1 | [M1](prd-m1-catalogo.md) | `PluginCatalog`: formato, assinatura, `sequence`, validade, recall por hash | — |
| 2 | [M2](prd-m2-origem-recall.md) | `InstalledPlugin.source`/`recalled`; o `PluginStore` bloqueia recolhido | M1 |
| 3 | [M3](prd-m3-instalar-catalogo.md) | daemon: baixar catálogo e pacote, conferir, instalar, atualizar, recall diário | M1, M2 |
| 2 | [M4](prd-m4-publicar.md) | CLI `tree-hash`/`catalog-keygen`/`catalog-sign` + workflow `plugins-release.yml` | M1 |
| 4 | [M5](prd-m5-app-descobrir.md) | app: aba Descobrir, selos, atualizar, recolhido bloqueado | M3 |
| 5 | [T1](prd-t1-collie-plugins.md) | fase 2: `plugin validate` e o repositório `collie-plugins` (PR, revisão, rehospedagem) | M4, fase 1 em uso |
| 5 | [T2](prd-t2-terceiros-app.md) | fase 2: autor de fora no app, helper com o time do autor | M5, T1 |

M2 usa o tipo `Recall` do M1, por isso vem depois. M2 e M4 rodam em paralelo (M2: `PluginManifest.swift`,
`PluginStore.swift`; M4: `collie/CLI.swift`, `scripts/ci/`, `.github/workflows/`).
