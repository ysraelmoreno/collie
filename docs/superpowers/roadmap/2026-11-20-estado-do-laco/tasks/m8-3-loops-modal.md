# M8.3 Modal "Ver tudo": Em andamento, Histórico e detalhe do laço

Leia `onda8.md`, `M8.1`, `M8.2`. Código: `Sources/CollieApp/HistoryPage.swift` (o detalhe de hoje é uma página HTML na Prévia), `CollieApp.swift` (~348 `onOpenHistory`), `OpenPanelSheet.swift` (exemplo de sheet), `WorkFeed` (`work`, `history`, `historyNotice`), o comando que devolve o `WorkArchive` de um id.

## Fazer
1. **Sheet "Laços"** (`LoopsSheet`) aberta por `ctx.onOpenLoops`; largura ~720, altura ~520, `Esc` fecha; duas abas (segmented): **Em andamento** e **Histórico** (a aba inicial vem do hook). Segue o estilo de `OpenPanelSheet`.
2. **Em andamento:** o laço de agora do cercado (nada rodando: "Nenhum laço rodando", e a aba abre em Histórico). Cabeçalho: título do trabalho, `3/5`, barra, fase e "desde hh:mm", limite do turno. Tabela de **tarefas** (ordem do laço): ícone de estado (`LoopStateIcon`), título, tentativa `k/max`, agente (nome do terminal; clique foca o terminal se vivo, senão "encerrado"), tempo da tentativa corrente. Atualiza ao vivo pelo `WorkFeed`.
3. **Histórico:** os últimos 20 do cercado (`HistoryRow`: título, quando, `4/6 feitas`, duração, cor do resultado, motivo). Clique abre o **detalhe no próprio modal** (botão "‹ Histórico" volta): dados, tarefas (estado, tentativas, commits curtos, razão/nota) e linha do tempo do `WorkArchive` (cortado nos 500 eventos; avisos "reconstruído"/"cortado" como a página). Botão **Abrir no canvas** mantém o artifact de hoje (`HistoryPage`, com a M7.1 intacta). Texto vindo do trabalho entra só como `Text` (nunca markdown nem atributo).
4. A seleção do histórico e a aba **não** persistem entre aberturas (sem estado novo em disco).

## Testes (escrever antes) — novo `Tests/CollieAppTests/LoopsModalTests.swift`
Modelo puro do modal (sem renderizar): aba inicial (laço rodando → Em andamento; sem laço → Histórico); linhas de tarefas com a tentativa certa (M8.1) e agente vivo/encerrado; histórico limitado a 20 na ordem dada; o detalhe monta de um `WorkArchive` (tarefas, timeline, avisos reconstruído/cortado); abrir no canvas chama o hook antigo com o id; texto malicioso (`<script>`, markdown) fica literal. O fake do daemon aplica a regra real.
