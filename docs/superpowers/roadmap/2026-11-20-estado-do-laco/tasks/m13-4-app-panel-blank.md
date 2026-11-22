# M13.4 Painel de app em branco logo depois do `attach`: reproduzir, achar a causa e corrigir

Leia `onda13.md`. Sintoma (do dono, 2026-11-21): um app adotado (`collie app adopt` + aprovação + `collie app attach`) abriu o painel **todo branco**; o serviço estava de pé (`/api/health` ok) e a página renderizava normalmente no Chrome; fechar o painel e dar `app attach` de novo (com o serviço já pronto) mostrou a página. O `app attach` retornou enquanto o serviço ainda estava em `starting`. Código: `Sources/ColliePlugins/WebPluginPanel.swift` (`apply()` ~122-135, `load` ~162-195, `didFailProvisionalNavigation` ~609 que já mostra "não está respondendo" com "Tentar de novo", `ruleJSON(origin:)` ~245), `Sources/CollieDaemonKit/AppServices.swift` (`ready`, estados `starting/running`), `PaddockApps.swift`.

## Hipóteses (a confirmar por teste ANTES de corrigir; já houve uma hipótese errada nesta casa: M10.5)
1. A carga acontece antes de o serviço escutar, e o `didFailProvisionalNavigation` não dispara (ou dispara e o placeholder some) → fica o `WKWebView` vazio.
2. A página (HTML) carrega, mas as regras de conteúdo (`ruleJSON`, "bloqueia tudo menos a origem") bloqueiam os recursos (`app.js`, `style.css`) na **primeira** compilação/uso da lista de regras da origem; o `app snapshot` de um painel recém-aberto listou os dois como `blocked`, e depois de reabrir a página funcionou.
3. Outra coisa (a corrida do `gen`, `teardown` no meio do `apply`).

## Fazer
1. **Reproduza primeiro:** um teste (em `Tests/ColliePluginsTests/`, no estilo de `WebPluginPanelTests.swift`, servidor de teste em `127.0.0.1` porta efêmera, sem `sleep`: espere por continuation/delegate) que abre o painel de app (a) com o serviço **fora do ar** e depois sobe o serviço, (b) com o serviço no ar mas servindo `index.html` com `<script src>` e `<link rel=stylesheet>` relativos, como o Quadro. Mostre qual dos dois deixa a página sem renderizar (o teste falha) e registre a causa real no commit. Se nenhuma das hipóteses reproduzir, diga isso no relatório da tarefa e pare em um teste que fixa o comportamento atual (não invente conserto).
2. **Corrija na causa, uma vez:** se for a hipótese 1, o painel espera o serviço (só carrega quando responde; enquanto isso mostra "Iniciando <app>…", e carrega sozinho quando subir, sem timer de parede: use o evento de estado do serviço ou tentativas ligadas ao delegate, com teto de tentativas) em vez de ficar em branco; se for a 2, a regra de conteúdo precisa estar efetiva antes da primeira carga e o recurso bloqueado nunca pode deixar a página vazia sem aviso.
3. Nenhum outro painel muda; os painéis de plug-in com `ui/` local (esquema `collie-plugin`) seguem iguais.

## Testes (escrever antes)
Os dois cenários acima (falham antes, passam depois); app com serviço que cai depois de carregar continua mostrando "não está respondendo" com "Tentar de novo"; painel de plug-in local sem mudança; `WebPluginPanelTests` e `HTMLSnapshotterTests` sem adaptação.

## Check
`scripts/check-onda13.sh m13-4`.
