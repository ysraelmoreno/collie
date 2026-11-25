# collie-plugins

Catálogo curado de plug-ins de terceiros do [Collie](https://github.com/ysraelmoreno/collie). Você abre um PR com o
seu plug-in; o dono do Collie lê o código e, se aprovar, faz o merge. O merge publica: o pacote é **rehospedado** como
release `plugin-<id>-v<versão>` em `ysraelmoreno/collie` e entra no catálogo assinado (`plugins.json`) que o app lê em
Preferências › Plug-ins › Descobrir. O app mostra o seu nome e "revisado pelo Collie".

> Estes arquivos vivem em `docs/superpowers/roadmap/2026-11-24-marketplace/collie-plugins/` no repositório do app
> (PRD T1). O dono os copia para `ysraelmoreno/collie-plugins`.

## Como submeter

1. **Seu publisher** (só no primeiro PR): `publishers/<seu-login>.json`, com o seu login do GitHub em minúsculas como
   `id`:

   ```json
   {"id": "fulana", "name": "Fulana Souza", "contact": "fulana@exemplo.com", "url": "https://github.com/fulana"}
   ```

   O `id` é o login: assim o check sabe que o arquivo é seu sem guardar mais nada. `collie` é do dono do app.

2. **O plug-in** (primeira versão): `plugins/<id>/plugin.json`, que diz de quem é e o resumo do cartão (pt-BR, até 200
   caracteres). O `publisher` de um plug-in não muda depois.

   ```json
   {"publisher": "fulana", "summary": "Um painel com o tempo de build de cada terminal."}
   ```

3. **A versão**, de um dos dois jeitos:
   - a pasta inteira em `plugins/<id>/<X.Y.Z>/` (com `collie-plugin.json`), ou
   - `plugins/<id>/<X.Y.Z>.json` apontando para uma tag de um repositório público seu:

     ```json
     {"repo": "https://github.com/fulana/build-time", "tag": "v0.1.0", "path": "plugin"}
     ```

     O CI clona a tag e copia a pasta; nada do seu repositório roda. Depois do merge, mudar a tag não muda nada: o
     pacote publicado é o que foi revisado.

   O manifesto tem que dizer o mesmo `id` e a mesma versão. Uma versão publicada não muda: corrija com uma versão nova
   (novo PR, nova revisão).

### Regras (o check de todo PR)

`collie plugin validate <pasta>` com o `collie` da última release do app, que é o que a instalação aceita:

- `collie-plugin.json` válido, `apiVersion` 1; até 5 000 arquivos e 64 MiB; sem link simbólico nem arquivo especial.
- `permissions.network` vazio (ou ausente): plug-in do catálogo não usa rede.
- Helper (`"helper": "bin/<nome>"`): um Mach-O assinado e notarizado com o **seu** Developer ID, com o identificador
  `dev.collie.plugin.<id>` (`codesign --options runtime --timestamp --identifier dev.collie.plugin.<id>`). O check
  imprime o `TeamIdentifier`, que vai para o catálogo (`helperTeamId`); o app confere essa assinatura antes de
  instalar. Sem Developer ID, sem helper.

E mais:

- O `publisher` do plug-in existe em `publishers/` e é você (o autor do PR).
- Fora de `plugins/` e `publishers/`, só o dono mexe.
- Rode `collie plugin validate <pasta>` antes de abrir o PR: exit 0 é ok; 1 lista os motivos, um por linha.

## Como funciona (para o dono)

| Arquivo | Quando | O quê |
|---|---|---|
| `.github/workflows/check.yml` | todo PR | `scripts/check-pr.sh` **da branch base** (o PR não muda o próprio check); sem segredos |
| `.github/workflows/publish.yml` | push em `main` (o merge) | monta, valida de novo, catálogo, rehospeda, assina e sobe |
| `scripts/touched.sh` | os dois | `<id> <versão>` de cada versão tocada |
| `scripts/assemble.sh` | os dois | monta a pasta do pacote (da pasta ou do `repo@tag`) |
| `scripts/check-pr.sh` | check | as regras acima |

O `publish.yml` usa o `scripts/ci/plugin-catalog.sh` do app (checkout de `ysraelmoreno/collie` na tag da última
release), troca o `publisher` do item pelo do autor e acrescenta o autor em `publishers` com `reviewedBy: "collie"`. O
`helperTeamId` sai do `codesign -dv` do helper do autor. As releases são sempre `--prerelease --latest=false`.

**Segredos** do `collie-plugins`: `PLUGIN_CATALOG_KEY` (a mesma chave do catálogo do app) e `COLLIE_RELEASE_TOKEN`
(token com escrita de release em `ysraelmoreno/collie`). Nenhum agente cria repositório nem segredo.

**Proteja `main`**: merge só pelo dono, com o check verde.

### Limitações conhecidas

- Dois escritores do catálogo (este `publish.yml` e o `plugins-release.yml` do app) não compartilham trava: se o
  catálogo mudar no meio, o `publish.yml` para antes de publicar qualquer coisa. Rode-o de novo.
- Criar a release `plugin-<id>-v<versão>` no app cria a tag, e a tag dispara o `plugins-release.yml` do app, que falha
  logo no início (não há `Examples/plugins/<id>`). É ruído, nada é publicado por ele; fica vermelho na aba Actions.
- Se a rehospedagem der certo e a subida do catálogo falhar, rodar de novo falha com "já existe": suba o catálogo à mão
  com `plugin-catalog.sh` ou apague a release órfã.

## Teste manual (primeira vez)

1. Num fork, PR com `publishers/<seu-login>.json`, `plugins/<id>/plugin.json` e `plugins/<id>/0.1.0/` — um plug-in de
   painel sem helper (copie `Examples/plugins/notas` do app, troque `id` e `name`).
2. O `check` fica verde (o log mostra `<id> 0.1.0: ok`). Teste também um vermelho: um link simbólico em `ui/` ou
   `"permissions": {"network": ["exemplo.com"]}` mostra o motivo.
3. Merge. O `publish` roda: a release `plugin-<id>-v0.1.0` aparece em `ysraelmoreno/collie` (pré-release), e o
   `plugins.json` do `plugins-catalog` tem `sequence` + 1, o item com `"publisher": "<seu-login>"` e o seu publisher
   em `publishers` com `"reviewedBy": "collie"`.
4. `collie plugin catalog-verify plugins.json --public <chave>` diz ok; o app lista o plug-in em Descobrir.
