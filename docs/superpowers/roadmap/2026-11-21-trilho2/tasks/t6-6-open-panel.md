# T6.6 Diálogo "Abrir painel" com o seletor da Prévia

Leia `README.md`. Código: `Sources/CollieApp/OpenPanelSheet.swift`, e a mensagem do daemon `Prévia: give --file <page.html> or --artifact <id>` (procure em `Sources`), `Sources/CollieClient/DaemonClient.swift` (listar artifacts: `artifact.list`).

## Problema
No diálogo "Abrir painel" com o plug-in **Prévia**, só há o campo "Nome (opcional)"; abrir sempre falha com `ProtocolError(... invalidArgs, message: "Prévia: give --file <page.html> or --artifact <id>")`.

## Fazer
1. Quando o plug-in escolhido exige um alvo (Prévia), o diálogo mostra um seletor: **Artifact** (lista do `artifact.list`, com título; pesquisável) **ou** **Arquivo** (um botão que abre o `NSOpenPanel` para `.html`/`.htm`). O botão "Abrir" fica **desabilitado** até haver um alvo, com a dica do que falta. O erro bruto do protocolo nunca aparece: falhas viram texto em português.
2. Os outros plug-ins não mudam. Um arquivo fora do que o app pode ler segue a regra de acesso existente (cartão), sem contorná-la.

## Testes (escrever antes) — novo `Tests/CollieAppTests/OpenPanelSheetTests.swift`
Modelo do diálogo (puro): Prévia sem alvo = não pode abrir; com artifact ou arquivo = pode; outros plug-ins = como antes; os argumentos montados (`--artifact id` / `--file caminho`) corretos; mensagem de falha em português.
