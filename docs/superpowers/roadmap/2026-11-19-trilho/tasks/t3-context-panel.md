# T3 Painel de contexto com a árvore de agentes

Leia primeiro o `README.md` desta pasta e abra `docs/pages/ui-layouts/a-trilho.html` (painel de 248 px). Depende de T1 (`AgentTree`) e T2 (`PaddockRail`), já no repositório.

Código: `Sources/CollieApp/Shell.swift` (`WorkspaceSidebar`, `PaddockHeader`, `StatusBar`, `HerdsSection`, `LotsSection`, `Shell`), novo `Sources/CollieApp/ContextPanel.swift`, `Tests/CollieAppTests/ShellTests.swift`. Para focar um terminal no canvas, use o mesmo caminho que o app já usa ao revelar um terminal (notificação de atenção / `onRemoteReveal` / `CanvasState`); não invente outro.

## Fazer

1. `ContextPanel` (View, largura 248) substitui `WorkspaceSidebar` na estrutura Completa, e `PaddockRail` fica à esquerda dele. Em ordem: cabeçalho (nome do cercado em 20 pt semibold, abaixo `branch ← base` ou o caminho, em mono; o menu do cercado `PaddockMenu` num botão "⋯"); os botões **Novo terminal** (primário) e **Abrir painel**; seção **AGENTES · N** com a árvore; **PAINÉIS · N**; **LAÇOS** (o cartão-resumo do laço em andamento, se houver, a partir do que a sidebar já mostra hoje); **REBANHOS** e **LOTES** (as seções que já existem, movidas).
2. **Árvore**: usa `AgentTree.rows`. Cada linha: caret (só no pai) que recolhe/expande os filhos (estado local `collapsed`, guardado em `@AppStorage` por cercado é opcional), ponto de status (forma + cor, como o resto do app), nome, selo âmbar com o número quando `pending > 0` (com `accessibilityLabel` "N cartões pendentes"), chip com o `preset`. Filhos com recuo e uma linha vertical fina à esquerda. O ponto do terminal que espera por você pulsa com `.animation` desligada quando "Reduzir movimento" está ativo (`accessibilityReduceMotion`).
3. Clicar numa linha seleciona o terminal e o foca no canvas (centraliza/realça pelo caminho existente). Duplo clique abre a edição (`onEdit`) se esse atalho já existir para o nó; senão, só o foco.
4. **Painéis**: linhas com o nome do painel; clique foca o painel (`collieFocusPanel` existe em `DockView.swift`).
5. O que a sidebar de 240 px tinha e agora vive em outro lugar: o **uso dos agentes** foi para o pé do trilho (T2); o **cabeçalho do cercado** (`PaddockHeader`) deixa de existir como faixa (virou o topo do painel); a **barra de status** continua no pé, só com o que ela já mostra. Remova `WorkspaceSidebar` e `PaddockHeader` sem deixar código morto; o `ZoomControls` migra para a faixa de abas na T4 (por ora, mantenha-o acessível onde estava, por exemplo no topo do painel, para o app não ficar sem zoom entre as tarefas).
6. A engrenagem do trilho chama `ctx.openPreferences` (acrescente a closure ao `ShellContext`, com o mesmo `openSettings()` de hoje por enquanto; a T5 troca o destino).
7. A estrutura Compacta não muda. `structureSwitchKeepsContent` continua passando: trocar Compacta ↔ Completa não refaz o canvas.

## Testes (escrever antes)

Em `ShellTests`: o teste existente `structureSwitchKeepsContent` segue verde com o `ShellContext` novo. Novo teste de que `Shell` na estrutura `.full` monta sem erro com um `DaemonClient` vazio (smoke com `NSHostingView`, como o teste existente). A lógica da árvore já é testada na T1; aqui não duplique.

O visual o dono confere à mão.
