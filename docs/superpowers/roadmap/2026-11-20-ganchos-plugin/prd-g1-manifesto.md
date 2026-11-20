# PRD G1: manifesto aceita `helper`, `hooks` e `project: read`

PRD geral: `README.md` desta pasta (contrato e decisões).

## Problema

`PluginManifest.validate()` recusa qualquer `helper` e qualquer permissão com "precisa de um Collie mais novo".
Sem isso nenhum plug-in pode declarar ganchos.

## Fazer (só `Sources/CollieCore/PluginManifest.swift` e `Tests/CollieCoreTests/PluginManifestTests.swift`)

1. Chave nova `hooks: [String]?`. Valores aceitos: `edit`, `stop`; sem repetição; no máximo 2. Outro valor:
   erro em português nomeando o valor.
2. `helper`: aceito quando `hooks` não é vazio. Caminho `bin/<nome>` com as mesmas regras de componente do `ui`
   (nome simples, sem `..`, sem nome começando com ponto). `helper` sem `hooks`, ou `hooks` sem `helper`: erro.
3. `permissions.project`: aceita `"none"` e `"read"`. `"write"` e qualquer `network` não vazio continuam recusados
   com a mensagem `newer`.
4. `commands[].runs == "helper"` continua recusado (`newer`).
5. Acessor público `hookEvents: [String]` (vazio quando não declara) para o daemon.
6. Manifestos atuais (sem as chaves novas) validam como antes; `Examples/plugins/notas` não muda.

## Aceite

Testes novos em `PluginManifestTests`: aceita helper+hooks+read; recusa hooks sem helper; recusa helper sem hooks;
recusa hook desconhecido; recusa `helper: "../x"` e `helper: "ui/x"`; recusa `project: "write"`; o manifesto do
Notas continua válido.

## Check

```
swift test --disable-sandbox --filter PluginManifestTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Commit com mensagem convencional, só dos seus arquivos; nada de push.
