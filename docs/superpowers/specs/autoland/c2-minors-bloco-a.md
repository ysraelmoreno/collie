# C2: minors do bloco A3-A6 e bugs do doctor

Lote de correções pequenas, cada uma com teste que falha sem ela. Não mude semântica além do descrito.

A. **Resumo do auto-land** (`Work/AutoLandSummary.swift`): (1) nome do arquivo com sufixo `-1`, `-2` em `EEXIST` (até 20), mantendo `O_EXCL`; (2) escrita completa (laço de `write` com EINTR) e, se falhar, `unlink` do parcial; (3) a linha do `notify` ao dono passa por `LotBoards.scrub` e usa `stop.code.rawValue`; (4) `landed` com `before` nil escreve "sem push" e a linha de reversão com `?`, nunca "nada integrado"; (5) falha de `store.get` ainda envia o `notify` mínimo.
B. **A4**: tarefa `abandoned` NÃO conta como concluída para o land (só `.done`); falha DEPOIS do merge (save/closeMerged) não vira `landConflict`: grava `before/after` e avisa que a base mudou; teste do handler `work.run --auto-land` recusando cercado não-fábrica, sem gate e com `--no-review`; confirme por teste que o land de modo merge sempre cria commit de merge (senão leia a base antes) e documente.
C. **Doctor** (`FactoryDoctor*.swift`): (1) "gate roda testes" não pode casar comentário (linha que começa com `#`) de script do gate; (2) `listPaths` para em 5000 caminhos e as personas ficam "sem arquivo": procure `docs/fabrica/personas` e `personas/` diretamente (sem varrer a árvore toda); (3) `scripts/factory-detect.sh` (Python): `#` no meio da linha em ini/cfg não é comentário e `site-packages` é podado; `-I` e site do usuário no detector; cada um com um caso em `scripts/test-factory-detect.sh`.
D. **CLI**: subpasta sem `.git` (cercado de pasta) não deve dar erro críptico em `factory doctor`: mensagem clara.

Check: `scripts/check-autoland-loop.sh c2`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
