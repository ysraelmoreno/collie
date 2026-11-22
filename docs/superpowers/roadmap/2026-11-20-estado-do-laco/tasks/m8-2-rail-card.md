# M8.2 Trilho: LAÇOS em card com barra e "Ver tudo"; HISTÓRICO sai

Leia `onda8.md`, `M8.1` e o desenho `docs/pages/ui-layouts/a-trilho.html` (o card de laço). Código: `Sources/CollieApp/ContextPanel.swift` (`loopsSection`, `historySection`, `sectionTitles`), `LoopSection.swift`, `Shell.swift` (`ShellContext`), `LoopStateIcon`.

## Fazer
1. **LAÇOS em card**, só com laço rodando (a regra de `LoopSection.visible` não muda): cabeçalho `LAÇOS` + botão de texto **Ver tudo** à direita; um card (borda `collieBorder`, cantos 10, fundo do token de superfície mais próximo) com: o **título do trabalho** (semibold, 1 linha), `3/5` à direita (cor de sucesso), barra de progresso fina (feitas/total; sem animação com Reduzir Movimento) e a linha de baixo `tentativa 2 · check rodando` (tentativa da tarefa em curso e a fase por extenso: "agente trabalhando", "check rodando", "portão rodando", "preparando"). Nenhuma lista de tarefas no Trilho.
2. **Ver tudo** chama o hook novo `ctx.onOpenLoops(tab)` (a M8.3 o liga ao modal; aqui só o hook, com `tab` = `.running`). O card inteiro também abre o modal.
3. **HISTÓRICO sai do Trilho:** remover `historySection` e o parâmetro `history` de `sectionTitles`; `HistorySection`/`HistoryRow` ficam (o modal usa). Atualizar `ContextPanelHistoryTests` (a seção não existe mais no Trilho) e `ContextPanelLoopsTests` (card em vez de linhas; sem laço, as mesmas seções de antes).
4. Acessibilidade: o card lê "laço <título>, 3 de 5 feitas, tentativa 2, check rodando"; o botão tem rótulo "Ver tudo".

## Testes (escrever antes) — novo `Tests/CollieAppTests/LoopCardTests.swift`
Modelo puro do card: título, `3/5`, fração da barra (0 com 0 tarefas, sem divisão por zero), linha de fase em cada fase, rótulo de acessibilidade; `ContextPanel.sectionTitles` nunca devolve HISTÓRICO; o hook é chamado ao tocar em Ver tudo (fake do `ShellContext`).
