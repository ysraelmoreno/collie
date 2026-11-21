# M9.1 UI: histórico alcançável, falha visível, ids estáveis

Leia `onda9.md` e os **achados B1, B2, B7 e B8** de `rev-onda78-report.md`. Código: `Sources/CollieApp/ContextPanel.swift` (`body`, `loopsSection`, `openLoops`), `Sources/CollieApp/LoopsSheet.swift` (`LoopsModal`, `HistoryOpener`, `open`, os `ForEach`), `CollieApp.swift` (~354 `historyNotice`, `onOpenLoops`), `LoopSection.swift`.

## Fazer
1. **B1:** o cabeçalho `LAÇOS` com o botão **Ver tudo** aparece também **sem laço rodando**, quando o cercado tem histórico (`!workFeed.history.isEmpty`); nesse caso sem card (só o cabeçalho e o botão, abrindo o modal na aba **Histórico**). Com laço rodando: como hoje (card). Sem laço e sem histórico: nada (como antes). `sectionTitles` e `ContextPanelLoopsTests` refletem as três situações.
2. **B2:** "Abrir no canvas" **não fecha** o modal antes da Prévia abrir; a falha (`ctx.historyNotice()` / `HistoryOpener.message`) aparece **dentro do modal**, texto fixo, até a próxima tentativa; só fecha quando a Prévia abriu.
3. **B7:** os `ForEach` de notas e razões usam `Array(enumerated())` com `id: \.offset`, nunca `id: \.self` em texto.
4. **B8:** `open(id)` só atribui `detail` se `loading == id` ainda; respostas fora de ordem são descartadas.

## Testes (escrever antes) — `Tests/CollieAppTests/HistoryReachTests.swift`
Modelo puro: as três situações do cabeçalho (rodando / só histórico / vazio); aba inicial Histórico sem laço; falha do hook deixa a mensagem e **não** fecha; notas duplicadas não colidem em id; duas aberturas A, B com A respondendo depois mostram B.
