# T4 Área principal: abas e Preferências no lugar do canvas

Leia primeiro o `README.md` desta pasta e abra `docs/pages/ui-layouts/a-trilho.html` (faixa de abas, aba Preferências). Depende de T3.

Código: `Sources/CollieApp/CollieApp.swift` (`ContentView.body`, a cena `Settings`), `Sources/CollieApp/Shell.swift`, `Sources/CollieApp/PreferencesView.swift` (já é uma View com sidebar própria e busca; hoje vive na cena `Settings`), `Sources/CollieApp/PreferencePage.swift`, `Tests/CollieAppTests/ShellTests.swift`.

## Fazer

1. Um enum `MainView { case canvas, preferences }` e o estado `mainView` no `ContentView` (`@State`; não persistir: o app sempre abre no canvas). Um tipo pequeno testável (`MainViewState`, struct de valor) com `show(_:)`, `back()` e `isPreferences`, sem SwiftUI, para a lógica poder ser testada.
2. A faixa de abas (`MainTabs`) no topo da área principal na estrutura Completa: abas **Canvas** e **Preferências** (com o atalho `⌘,` ao lado), o campo de busca de comandos (`CommandField`, ⌘K) alinhado à direita e o zoom (`ZoomControls`, que sai do painel de contexto aqui). A aba ativa tem o sublinhado de acento do protótipo. Cada aba é um botão com `accessibilityAddTraits(.isSelected)`.
3. **Preferências no lugar do canvas**: quando `mainView == .preferences`, a área central mostra `PreferencesView` (a mesma View, preenchendo o espaço, sem moldura de janela de Ajustes). O **canvas continua montado** por baixo (por exemplo num `ZStack` com opacidade 0, `allowsHitTesting(false)` e `accessibilityHidden(true)` quando escondido), para os terminais não serem refeitos e o zoom/posições ficarem. Os docks (esquerdo/direito/inferior) ficam escondidos junto com o canvas enquanto as Preferências estão abertas.
4. `PreferencesView` precisa funcionar nos dois lugares até a T5 remover a cena (largura livre; nada de `.frame(width:)` fixo de janela que atrapalhe). Se ela depende do ambiente da cena `Settings`, resolva sem duplicar a View.
5. A cena `Settings` ainda existe nesta tarefa (a T5 a troca).

## Testes (escrever antes)

`MainViewTests` (novo arquivo): `MainViewState` começa no canvas; `show(.preferences)` e `back()`; `back()` fora das Preferências não muda nada. Em `ShellTests`, um teste no estilo de `structureSwitchKeepsContent`: alternar `mainView` entre canvas e preferências várias vezes **não refaz** o canvas (`made == 1`, `dismantled == 0` no `Probe`). Para isso `Shell` (ou um wrapper testável) recebe o `mainView` e o conteúdo das Preferências como parâmetros, mantendo o canvas na mesma posição da hierarquia.
