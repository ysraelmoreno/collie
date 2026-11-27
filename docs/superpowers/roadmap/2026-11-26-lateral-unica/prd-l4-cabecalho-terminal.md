# PRD L4: cabeçalho do terminal e pedido dentro dele

PRD geral: `README.md`. Spec: "Canvas" (cabeçalho, pedido). Onda 1.

## Problema

O cabeçalho mostra até seis etiquetas (Pastor, pastoreando n, preset, modelo, livre, lote, estado) e três ícones; o
cartão de sandbox flutua no canvas longe de quem pediu.

## Fazer (`TerminalNodeView.swift`, `AccessViews.swift`, teste novo `Tests/CollieAppTests/TerminalHeaderTests.swift`)

1. **Modelo puro** `TerminalHeader.make(record:, badge:, connections:, lot:) -> (title, state, menuItems)`: o
   cabeçalho mostra só ponto + nome + estado em palavra ("trabalhando", "esperando você", "concluído", "parado").
   Vão para o menu ⋯ (e para o `.help` do nome): papel Pastor e quantos pastoreia, preset, modelo, livre/sandbox,
   lote. Exceção: terminal **livre** mantém um aviso visível (é risco), como ícone com texto no hover.
2. Os ícones de ação aparecem só no hover ou na seleção; ⋯ sempre alcançável pelo teclado.
3. **Pedido dentro do terminal**: os cartões de acesso/coleira/app do terminal aparecem como faixa no pé do próprio
   nó (pergunta + caminho em mono + Permitir / Nesta sessão / Negar), reusando as ações de `AccessViews`. O cartão
   solto no canvas sai. Vários pedidos: o mais antigo e "+n".

## Aceite

`TerminalHeaderTests`: estado em palavra por badge; Pastor vai para o menu com a contagem; livre gera aviso visível;
lote no menu; terminal sem badge = "parado". Testes existentes que tocam `AccessViews` (ex.: `AccessStripTests`)
continuam passando.

## Check

`lockf -k .collie/build.lock swift test --disable-sandbox --filter '(TerminalHeaderTests|AccessStripTests|NodeActionsTests)'`

## No app real

Cabeçalho com nome e estado; ⋯ mostra o resto; pedido aparece dentro do terminal que pediu e some ao aprovar.
