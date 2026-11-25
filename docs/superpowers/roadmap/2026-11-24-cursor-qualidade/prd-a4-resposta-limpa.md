# PRD A4: resposta por ociosidade sem a moldura do Ink

PRD geral: `README.md` desta pasta (problema 6). Roda depois do A3 (mesmo arquivo).

## Problema

Um Cursor que não chama `collie reply` termina o ask por ociosidade (`AskCoordinator.pollIdle`, linha 1035), e a
resposta é `scrollback.text(since: mark)`: o Ink repinta a tela inteira a cada quadro do spinner, então o asker recebe
centenas de cópias do rodapé (`→ Add a follow-up`, `Composer 2.5 · 20%`, `⠘⠣ Running`). Na rodada 1b foram ~1k linhas
para uma tabela de 17 linhas no fim. O `check` sem `--screen` tem o mesmo ruído.

`check --screen` já resolve a parte da tela: `CommandRouter.screen(_:)` (linha 583) reproduz a saída num emulador do
tamanho do terminal com `config.screenRenderer` (`ScreenRenderer.render`).

## Fazer

1. Para `cursorTUI`, a resposta por ociosidade é a **tela renderizada** no fim do turno, não o scrollback: o
   `AskCoordinator` recebe o renderizador por injeção (closure opcional, como `config.screenRenderer`; sem ele, o
   comportamento de hoje).
2. Da tela, tirar a moldura fixa do Cursor: as linhas a partir da barra (`→ `) até o fim (barra, rodapé com modelo e
   caminho). Uma função pura `CursorScreen.answer(_ screen: String) -> String`, testável sem PTY.
3. Se a resposta passou da altura da tela (a tela mostra só o fim), marcar `truncated: true` e acrescentar a linha
   `(resposta cortada na altura da tela: collie check <nome> --screen)`.
4. Fora do escopo: o `check` sem `--screen` (continua o fluxo cru; é o que se pede para depurar).

## Aceite

- `CursorScreen.answer` com telas capturadas em 2026-11-24 (salvar duas como fixture em `Tests/Fixtures/`): só o texto
  da resposta, sem barra, rodapé nem spinner.
- Ask por ociosidade a um PTY falso Cursor que repinta o rodapé 50 vezes: a saída não contém o rodapé (teste).
- Sem renderizador: igual a hoje (teste).

## Check

```
swift test --disable-sandbox --filter AskTests && swift test --disable-sandbox --filter CursorScreenTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
