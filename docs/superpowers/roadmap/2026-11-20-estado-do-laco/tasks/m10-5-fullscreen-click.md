# M10.5 O botão de tela cheia do terminal não responde no canvas

Leia `onda10.md`. Sintoma (do dono): no **canvas** o clique no ⤢ da barra de título de um **terminal** não faz nada; em tela cheia o botão funciona; o atalho ⌘⏎ e o item "Tela cheia" do menu funcionam; **painéis** não têm o problema. Código: `Sources/CollieApp/TerminalNodeView.swift` (`TitleHost` ~476: `mouseDown` chama `onSelect`, `onClick`→`focus()` e `super`; `mouseUp` chama `super` e depois `onMouseUp`→`released()`→`bringToFront()` ~369-377), `FullscreenButton` em `PanelNodeView.swift` ~192, `CanvasViewport.swift` ~197 (`shown`, `canvas.fullscreen = nil`) e ~245 `syncFullscreenChrome`.

## Hipótese (a confirmar com teste ANTES de corrigir)
`bringToFront()` (tira e recoloca a view do nó no canvas) roda no `mouseUp`, logo depois do `super.mouseUp`; o `Button` do SwiftUI dispara a ação **depois** (fim do gesto), com a view já recolocada, e o clique é cancelado. Em tela cheia o nó já é o último da pilha e `bringToFront` sai sem mexer. Painéis não passam por esse caminho.

## Fazer
1. **Reproduza primeiro (sistema, não adivinhação):** teste que monta um `TitleHost` com o `FullscreenButton` dentro de uma view-pai com **outro irmão por cima**, e envia `mouseDown`/`mouseUp` sintéticos pela janela, com `onMouseUp` fazendo o mesmo que `released()` (recolocar a view). Mostre que a ação do botão **não dispara** (o teste falha) e registre no relatório da tarefa qual é a causa real. Se a hipótese não se confirmar, investigue a causa verdadeira (ex.: `canvas.fullscreen = nil` em `CanvasViewport` ~197 revertendo a entrada, `focus()` no `mouseDown`, o `onSelect`), sempre com teste que reproduz antes.
2. **Corrija na causa, uma vez:** o caminho provável é adiar `bringToFront()` para o próximo ciclo do run loop (a ação do botão termina antes de a view ser recolocada), mantendo "nunca no meio de um arrasto" e a restauração do foco. Confira os outros botões da barra do terminal (menu `…`, Reiniciar) e o corpo do nó: nenhum deve regredir.
3. O atalho, o menu e a tela cheia de painéis seguem iguais.

## Testes (escrever antes) — `Tests/CollieAppTests/TerminalFullscreenClickTests.swift`
O clique sintético no ⤢ com outro nó na frente **dispara** a ação (falha antes da correção, passa depois); o clique **sem** nó na frente continua disparando; um arrasto pela barra **não** dispara a ação nem recoloca a view no meio; depois do clique a view fica à frente e o foco volta ao terminal que o tinha. Sem `sleep`: espere por continuation.
