# F4: minors do motor V1 a V4 (revisor 3)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-1.md` (revisor 3). NÃO mexa no tratamento de symlink de `~/.claude.json` (MINOR 5: decisão do dono). Arquivos: `Sources/CollieDaemonKit/SandboxCommands.swift`, `Sources/CollieDaemonKit/Work/WorkLoopReview.swift`, `Tests/CollieDaemonKitTests/WorkCommandTests.swift`, `WorkLoopReviewTests.swift`.

1. `access.request` de um terminal em `loopReviewers` responde `shown: false` com mensagem própria ("revisor do laço: nada é liberado durante a revisão"), não "Pedido mostrado ao usuário". Teste.
2. Teste da V4 mais forte: a negação de um terminal comum gera cartão (`cards.cards` contém o terminal) e `silent[comum] == nil`; a de uma faixa segue como hoje (caso novo). O teste deve FALHAR se `raise` silenciasse todos os terminais enquanto há um revisor.
3. V3: `F_FULLFSYNC` (ou `fsync`) do temporário antes do `rename`; antes do `rename`, comparar `stat` (inode, tamanho, mtime) com o do início da leitura e, se mudou, reler e refazer a mescla uma vez; se mudar de novo, desistir com nota (não sobrescrever). Teste com o hook `beforeRename` que já existe: mudar o arquivo no meio e conferir que o conteúdo do usuário não se perde.

Check: `scripts/check-fabrica-loop.sh f4`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
