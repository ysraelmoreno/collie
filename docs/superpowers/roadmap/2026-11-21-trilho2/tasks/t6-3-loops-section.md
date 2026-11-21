# T6.3 Seção LAÇOS no `ContextPanel`

Leia `README.md` e `T6.2`. Código: `Sources/CollieApp/ContextPanel.swift` (seções AGENTES, PAINÉIS, Rebanhos, Lotes), `Sources/CollieApp/PaddockRail.swift` (como o Pasto some quando vazio: mesmo estilo de regra), o desenho `docs/pages/ui-layouts/a-trilho.html` (a vista de laços).

## Fazer
1. Uma seção **LAÇOS · n/m** **abaixo de Lotes**, desenhada só quando `LoopSection.visible`. Cada linha: ícone de estado (feita ✓, rodando ◐ animado só com Reduzir Movimento desligado, adiada –, aberta ○), título da tarefa truncado, `tentativa k/max`. No topo da seção: a fase e "desde hh:mm". Cores só de `CollieTheme`. Acessível: rótulo de cada linha com estado em texto.
2. **Nada** aparece sem laço rodando: sem cabeçalho, sem espaço. A Compacta e a janela de Ajustes não mudam.
3. Clicar numa linha abre o terminal do agente daquela tentativa, se ainda existir (senão, nada).

## Testes (escrever antes) — novo `Tests/CollieAppTests/ContextPanelLoopsTests.swift`
Com o modelo da T6.2: a seção existe só nas condições da tabela; contagem do cabeçalho; ordem das linhas; rótulo de acessibilidade; o `ContextPanel` sem laço continua com as mesmas seções de antes (regressão por lista de títulos de seção).
