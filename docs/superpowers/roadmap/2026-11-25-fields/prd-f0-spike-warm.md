# PRD F0: spike — o `.build` clonado compila incremental noutro caminho?

Plano: `README.md`. Spec: "Respostas à revisão" 12.

## Pergunta

Um `.build` do SwiftPM clonado (`cp -c -R`, `clonefile`) da worktree do cercado para
`<repo>/.collie/paddocks/field-x/.build` deixa o primeiro `swift build --build-tests` do field incremental, ou
recompila do zero (caminhos absolutos no SwiftPM e no module cache do clang), ou dá erro?

## Fazer (sem código do produto)

1. Com o `.build` do cercado quente (`swift build --build-tests` acabou de passar), `git worktree add --detach` em
   `.collie/paddocks/field-spike` no HEAD.
2. Medir três casos, cada um com `time swift build --build-tests` dentro do lock:
   - **frio:** sem `.build`;
   - **clonado:** `cp -c -R .build .collie/paddocks/field-spike/.build`;
   - **clonado + 1 arquivo tocado:** clonar, `touch Sources/CollieCore/Work.swift`.
3. Para cada um: tempo, se terminou ok, quantos módulos o log diz que compilou (`Compiling` por alvo), erro de cache se
   houver. Repetir o "clonado" uma vez com o build do cercado rodando ao mesmo tempo.
4. Se "clonado" ≈ "frio", testar `-Xswiftc -file-prefix-map` / `--scratch-path` apontando para um diretório de caminho
   fixo (ex.: `<raiz>/build-cache/<cercado>`) e medir de novo.
5. Escrever `docs/superpowers/spikes/2026-11-25-field-warm/REPORT.md` com a tabela e a **decisão**: `warm` clona
   `.build` (funciona), `warm` usa caminho fixo (com o comando exato), ou `warm` sai do F1/F2 (não vale).
6. `git worktree remove --force .collie/paddocks/field-spike`.

## Check

```
test -f docs/superpowers/spikes/2026-11-25-field-warm/REPORT.md && grep -q '^## Decisão' docs/superpowers/spikes/2026-11-25-field-warm/REPORT.md
```

Commit `docs(spike): field warm build cache` (só o REPORT).
