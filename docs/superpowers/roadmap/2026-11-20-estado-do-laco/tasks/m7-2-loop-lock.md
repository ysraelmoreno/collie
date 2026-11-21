# M7.2 Um laço por cercado vale também com trabalho fechado; `reset` e quarentena sem glob nem TOCTOU

Leia `onda7.md` e os **achados A2, A5 e A6** de `rev-onda6-report.md`. Código: `WorkLoopCommands.swift` (~50-51, `work.list(includeClosed: false)` e `others.contains { $0.loop?.state == .running }`), `Work/WorkLoop.swift` (~171 `workGone`, ~795 `["reset","-q","--"] + keep`, ~756 `diff --name-only` sem `-z`), `Work/WorkLoopLanes.swift` (~48 `clearQuarantine`), `Work/LaneIntegrator.swift` (~205-216 o move da quarentena, ~251 `removeItem`).

## Fazer
1. **Trava:** a trava "um laço por cercado" considera **qualquer** trabalho do cercado com `loop.state == .running`, **inclusive fechado** (`includeClosed: true` ou o registro de laços do cercado), com a mensagem existente. Um trabalho fechado com laço rodando continua válido (M6.4); só impede **outro** laço de começar.
2. `clearQuarantine` só esvazia a quarentena do **próprio** laço (marca do trabalho dentro da pasta) e nunca a de outro laço vivo; sem marca = não toca.
3. `discard` do laço serial: `git --literal-pathspecs reset -q -- <keep>` e `diff --name-only -z` (nome com newline/glob lido certo).
4. **Quarentena (TOCTOU):** antes do move, resolver o caminho de origem e exigir que fique **dentro** da árvore real do cercado (`src.resolvingSymlinksInPath()` com prefixo da raiz real); fora disso, não move e anota.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopLockClosedWorkTests.swift`
Cercado com um trabalho **fechado** cujo laço ainda roda ⇒ `work run` de outro trabalho é recusado; depois que o laço termina ⇒ aceito; o laço B não esvazia a quarentena do laço A; `discard` com um arquivo `[x].txt` mantido no stage e outro `x.txt` ⇒ só o literal; nome com newline tratado; diretório pai trocado por symlink ⇒ o arquivo de fora **não** é movido. Suítes de integração e de laço seguem verdes.
