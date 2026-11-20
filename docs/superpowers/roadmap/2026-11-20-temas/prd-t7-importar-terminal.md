# PRD T7: importar tema de terminal e cores ANSI (a detalhar depois do T6)

PRD geral: `README.md` desta pasta. Depende de T6 em uso.

## Por que está separado

O protótipo mostra um tema "importado" de terminal. Isso só faz sentido junto com as 16 cores ANSI, que o app hoje
não define (ficam com o SwiftTerm). As duas decisões do dono foram tomadas (abaixo); nenhuma bloqueava T1 a T6.

## Decisões do dono (2026-11-20)

1. **As cores ANSI fazem parte do tema**, na chave `terminal` que o arquivo já reserva.
2. **Formato a importar: Ghostty** (texto `chave = valor`). iTerm e outros só se alguém pedir.

## Em aberto

**Como derivar as cores da interface** de um tema que só tem fundo, texto e 16 cores. Proposta inicial:
fundo → `background`, texto → `text`, azul ou verde brilhante → `accent`, amarelo → `attention`,
vermelho → `danger`, e o resto herdado; o usuário ajusta no editor.

## Fatias previstas

- **T7.1** Cores ANSI no formato e no terminal (`TerminalNodeView.applyColors`), com teste de leitura do arquivo.
- **T7.2** Leitor puro de Ghostty → `ThemeFile`, com arquivos de exemplo nos testes.
- **T7.3** "Importar…" aceita esses formatos; grupo "Terminal" na lista do editor.
