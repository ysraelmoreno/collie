# T2 Coluna de cercados (trilho)

Leia primeiro o `README.md` desta pasta e abra `docs/pages/ui-layouts/a-trilho.html` como referência visual (coluna da esquerda, 64 px).

Código: crie `Sources/CollieApp/PaddockRail.swift` e `Tests/CollieAppTests/PaddockRailTests.swift`. O que já existe e deve ser reaproveitado, não duplicado: `PaddockActions` (selecionar, novo cercado, menu), `PaddockMenu`, `PaddockStatusDot`/status em `PaddockBar.swift`, `UsageFeed` e `UsageButton`/popover de uso em `Shell.swift`, `CollieMark`, as cores `Color.collie*`.

## Fazer

1. `PaddockRail` (View) de largura fixa 64: o `CollieMark` no topo; um botão por cercado, quadrado de 40 px com cantos arredondados, mostrando a **inicial** do nome, o selecionado em destaque (cor de acento) e um ponto de status no canto (o mesmo `PaddockStatusDot`, que já tem forma + cor); o **Pasto** como primeiro item; o botão tracejado "+" (Novo cercado, `NewPaddockButton`/`paddocks.newPaddock`); no pé, o resumo de uso (percentual do provedor mais alto, mini barra; clique abre o popover de uso que já existe) e a engrenagem de Preferências (recebe uma closure `openPreferences`, ainda sem ligação — a T5 liga).
2. Cada botão de cercado: `.help` com nome e status, `accessibilityLabel` com o nome, `accessibilityValue` com o status, `.isSelected` quando é o atual, `contextMenu` com `PaddockMenu`.
3. Uma função pura `PaddockRail.initial(of:)`: primeira letra do nome em maiúscula, ignorando espaços e símbolos iniciais; nome vazio dá "?". Dois cercados com a mesma inicial continuam distintos pelo `help`/rótulo.
4. A view não é ligada ao `Shell` ainda (a T3 liga). O app compila.

## Testes (escrever antes) — `PaddockRailTests`

`initial(of:)`: "collie" → "C", " web" → "W", "-x" → "X", "" → "?", nome com acento ("água") → "Á".
