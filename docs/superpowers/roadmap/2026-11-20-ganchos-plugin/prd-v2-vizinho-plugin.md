# PRD V2: plug-in Vizinho empacotado e teste de ponta a ponta

PRD geral: `README.md` desta pasta. Depende de G4, G5 e V1.

## Problema

`VizinhoKit` é só uma biblioteca. Falta virar uma pasta de plug-in instalável e provar o caminho inteiro: edição
do agente → daemon → helper no sandbox → orientação de volta.

## Fazer

Arquivos: alvo executável `collie-vizinho` (`Sources/collie-vizinho/main.swift`, só lê stdin, chama
`Vizinho.respond`, escreve stdout); `Package.swift`; `Examples/plugins/vizinho/` (`collie-plugin.json`,
`ui/index.html`, `LICENSE`); `scripts/build-vizinho-plugin.sh`;
`Tests/CollieIntegrationTests/VizinhoPluginTests.swift`; `docs/feature-map.md`.

1. `main.swift`: no máximo 20 linhas; qualquer erro → `{}` e exit 0.
2. Manifesto: `id: "vizinho"`, `hooks: ["edit"]`, `helper: "bin/vizinho"`, `permissions.project: "read"`,
   `ui: "ui/index.html"`, sem comandos.
3. `ui/index.html`: uma página estática, com os tokens do tema (`collie.theme`), que explica em três linhas o que
   o plug-in faz. Sem lógica.
4. `scripts/build-vizinho-plugin.sh [<destino>]`: `swift build -c release --product collie-vizinho`, copia
   `Examples/plugins/vizinho` para o destino (padrão `.build/plugins/vizinho`) e põe o binário em `bin/vizinho`.
   O binário não é commitado.
5. `docs/feature-map.md`: entrada "Vizinho" (para que serve, arquivos, como verificar).

## Aceite

`VizinhoPluginTests`: monta a pasta com o script, instala num daemon de teste, cria um projeto temporário com 5
arquivos `*Panel.swift` que importam `A`, envia `plugin.hook` `edit` para um sexto arquivo sem o import, e recebe
um `guide` que cita o arquivo modelo e "5 de 5". Um arquivo sem irmãos devolve vazio.

Verificação manual (registrar o resultado no PRD ao terminar): instalar no Collie real, pedir a um terminal Claude
para criar um `*Panel.swift`, conferir a orientação no transcript.

## Check

```
scripts/build-vizinho-plugin.sh && swift test --disable-sandbox --filter VizinhoPluginTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
