# PRD G6: a instalação mostra o que o plug-in pode fazer

PRD geral: `README.md` desta pasta. Depende de G1 (manifesto com `hooks`, `helper`, `permissions`).

## Problema

Um plug-in com ganchos roda um programa a cada edição e lê o projeto. O usuário precisa ver isso antes de
instalar, e depois, na lista. Nada é concedido em silêncio (regra do design de plug-ins).

## Fazer

Arquivos: `Sources/CollieApp/PluginsPreferences.swift` (e a folha de confirmação de instalação que ele usa);
`Sources/CollieDaemonKit/PluginAdminCommands.swift`; `Sources/collie/CLI.swift` só se a saída de
`plugin install`/`plugin list` for montada lá; `docs/plugins/api-v1.md`; `docs/referencia.md`; testes nos alvos
correspondentes.

1. Função pura em `CollieCore` (arquivo novo `PluginPermissionLines.swift`):
   `PluginManifest.permissionLines -> [String]`, em pt-BR:
   - `hooks` com `edit`: "Roda um programa a cada arquivo que um agente edita";
   - `hooks` com `stop`: "Roda um programa ao fim de cada turno e pode pedir que o agente continue";
   - `project: read`: "Pode ler os arquivos do projeto";
   - sem nada disso: lista vazia.
2. App: a confirmação de instalação e a linha do plug-in em Preferências → Plug-ins mostram essas linhas.
   Substituir um plug-in por uma versão que pede mais do que a instalada exige nova confirmação mostrando as
   linhas novas.
3. `plugin.list` ganha `hooks` e `permissions` por plug-in. `collie plugin install`, fora de terminal, imprime as
   linhas depois de instalar.
4. `docs/plugins/api-v1.md`: seção "Ganchos de agente" com o manifesto, o contrato (copiar do PRD geral), o
   sandbox, os prazos, o fail open e um helper de exemplo em `sh` de 10 linhas. Tirar `helper` e
   `permissions.project: read` da lista do que é recusado.
5. `docs/referencia.md`: uma entrada curta apontando para a seção.

## Aceite

- Teste de `permissionLines` para as quatro combinações.
- Teste de `plugin.list` com um plug-in de ganchos: `hooks` e `permissions` presentes.
- Teste (ou caso em teste existente de instalação) de que uma versão com mais permissões pede confirmação.
- `grep -q "Ganchos de agente" docs/plugins/api-v1.md`.

## Check

```
swift test --disable-sandbox --filter 'PluginPermissionLinesTests|PluginStoreTests' && grep -q "Ganchos de agente" docs/plugins/api-v1.md
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Commit com mensagem convencional, só dos seus arquivos; nada de push.
