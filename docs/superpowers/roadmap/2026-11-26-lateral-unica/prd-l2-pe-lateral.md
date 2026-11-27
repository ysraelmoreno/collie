# PRD L2: pé da lateral

PRD geral: `README.md`. Spec: "Pé". Onda 2 (depois de L1). Junto com L3, arquivos diferentes.

## Problema

Pedidos de sandbox, coleira e app ficam soltos no canvas; uso é um "65%" sem explicação; a desconexão some na barra
de status, que vai sair.

## Fazer (novos `Sources/CollieApp/SidebarFooter.swift`, `Tests/CollieAppTests/SidebarFooterTests.swift`; em
`Sidebar.swift` só passar o pé; `UsagePopover.swift` se precisar)

1. **Modelo puro** `NeedsYou.items(accessCards:, leashRequests:, appCards:, terminals:) -> [Item]` com terminal,
   nome do agente, frase curta ("quer gravar fora do projeto", "quer uma coleira para…", "app pede…") e o alvo.
   Ordem: mais antigo primeiro.
2. **Pé**: "Precisa de você (n)" (só com n > 0; ponto laranja + palavra) abre popover com a lista; cada item tem as
   ações de hoje do cartão (Permitir / Nesta sessão / Negar, reusando `AccessViews`) e "Ver no canvas" (`ctx.focus`).
   Aprovar aqui some do terminal (mesma fonte: o client). "Uso n%" abre `UsagePopover` com uma linha do que o número
   significa. "Preferências ⌘," chama `ctx.openPreferences`. Desconectado: linha de aviso (cor danger + texto) só
   enquanto `client.state != .connected`.
3. Recolhida: só ícones com número.

## Aceite

`SidebarFooterTests`: n conta os três tipos; frase por tipo; app card do usuário (`by == nil`) não conta (como
`AgentTree.pending`); ordem; lista vazia esconde o item.

## Check

`lockf -k .collie/build.lock swift test --disable-sandbox --filter SidebarFooterTests`

## No app real

Um pedido aparece no pé e no terminal; aprovar num some do outro; "Ver no canvas" centraliza o agente.
