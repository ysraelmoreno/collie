# B1.4 Evidência limpa e tarefa feita à mão rotulada

Achados 3 e 4 da revisão da onda 2 (`.collie/briefs/rev-wave2-report.md`, local).

## Fazer

1. Evidência (`WorkLoop.swift`, onde `commits` e `checkTail` são montados): cada assunto de commit é cortado em 200 caracteres (por `Character`, não por byte) e tanto `commits` quanto `checkTail` perdem caracteres de controle, de formato (bidi, U+202E) e sequências ANSI antes de gravar. Reaproveite o filtro que `RerailText.clean` / `AccessCopy.shown` já usam, sem copiar.
2. Aviso de fim do laço (`WorkStatusText.swift`, `loopEnded`): uma tarefa `done` da lista do laço que **não tem evidência** aparece como `✓ <título> · marcada à mão, sem check` e conta em "N feitas" como antes, mas o aviso distingue. Também: `work.task.done` de uma tarefa `inProgress` de um laço rodando grava a tarefa relendo-a no momento da escrita (sem sobrescrever `evidence`/`tries` recém-gravados pelo laço).

## Testes

- assunto de commit com 5000 caracteres e com U+202E e ANSI: gravado com ≤ 200 e sem os caracteres.
- `checkTail` com ANSI: limpo.
- aviso de fim com uma tarefa feita à mão dentro do laço: tem o rótulo "marcada à mão, sem check".
- `work.task.done` concorrente com a aprovação do laço não perde a evidência.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência nova. Textos em português. Commits convencionais; nada de push. Não tocar em `scripts/ci/`.
