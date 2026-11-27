# PRD L5: laço flutuante preso ao terminal

PRD geral: `README.md`. Spec: "Canvas" (laço). Onda 1. Ideia do dono: o laço é um painel flutuante ao lado do
terminal que trabalha nele.

## Problema

O laço vive num cartão do painel de contexto (que sai) e num modal; quem olha o terminal não vê o laço que ele roda.

## Fazer (novo `Sources/CollieApp/LoopFloat.swift`, `LoopSection.swift`, `LoopsSheet.swift`, `CanvasViewport.swift`;
teste novo `Tests/CollieAppTests/LoopFloatTests.swift`)

1. **Modelo puro** `LoopFloat.make(work:, terminals:) -> [Item]`: para cada laço rodando, o terminal dono (o que roda
   o laço; reuse o que `LoopCard`/`LoopSection` já sabem), título, n/total, tarefa atual, tentativa, estado do check,
   e a lista de tarefas com ✔ / ● / ◌. Sem terminal dono visível: item sem âncora.
2. **Vista** desenhada pelo `CanvasViewport` colada à direita do nó dono (acompanha mover/zoom do nó; à esquerda se não
   couber): expandida (≈ 260 pt: título, barra n/total, tarefas, Parar / Adiar tarefa / Histórico) ou **pílula**
   ("laço 3/7 · check rodando"). Estado recolhido por laço em `@AppStorage`. Coleira curta visual até o nó. Parar e
   Adiar usam as ações de hoje (`LoopsSheet`); Histórico abre o modal de hoje.
3. Sem âncora: a pílula fica no canto inferior esquerdo do canvas.
4. Não mexer em `ContextPanel` (L3 apaga).

## Aceite

`LoopFloatTests`: item por laço rodando com o dono certo; contagem e tarefa atual; ícones por estado de tarefa;
laço sem dono sem âncora; laço terminado some. `LoopSectionTests`, `LoopCardTests`, `LoopsModalTests` passam.

## Check

`lockf -k .collie/build.lock swift test --disable-sandbox --filter '(LoopFloatTests|LoopSectionTests|LoopCardTests|LoopsModalTests)'`

## No app real

Com um laço rodando, o painel aparece ao lado do terminal dono, acompanha ao arrastar, recolhe em pílula e volta;
Parar funciona.
