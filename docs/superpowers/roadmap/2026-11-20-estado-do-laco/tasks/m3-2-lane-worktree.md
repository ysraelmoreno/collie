# M3.2 Worktree da faixa

Leia `onda3-paralelismo.md`. Depende de M3.1. Código: novo `Sources/CollieDaemonKit/Work/LaneWorktree.swift`. **Antes de escrever**, leia como o daemon cria e remove o worktree de um cercado (`paddock create`/`delete`/`land`; procure `worktree add` em `Sources/CollieDaemonKit/`) e **reaproveite** esse código e a convenção de onde ficam os worktrees (a raiz do repositório, não o daemon root), em vez de reinventar. Anote em um comentário no topo do arquivo qual código reaproveitou.

## Fazer

1. `LaneWorktree.create(repoRoot:, base: String (sha), work: UUID, task: String) async throws -> Lane` onde `Lane { path: URL, branch: String, base: String }`: `git worktree add -b collie/lane/<work8>-<task> <path> <base>`, com `work8` os 8 primeiros hex do id, e `task` validado (`[A-Za-z0-9._-]{1,40}`, sem `..`). O `path` fica no lugar que os worktrees de cercado usam, num nome que **não colide** com cercados (prefixo `lane-`). Branch ou caminho já existentes: erro claro, nunca sobrescreve. Nenhuma faixa nasce fora do repositório.
2. `LaneWorktree.remove(_ lane:)`: `git worktree remove --force` e `git branch -D`, **e** apaga o diretório se sobrou; idempotente (remover duas vezes não falha).
3. `LaneWorktree.orphans(repoRoot:, knownWork: Set<UUID>) async -> [Lane]`: as faixas (por prefixo de branch `collie/lane/`) que não pertencem a um trabalho em curso; e `sweep(repoRoot:, active: Set<UUID>)` que remove as órfãs (usado na varredura de início do daemon, M3.6). Nunca toca em um worktree que **não** tenha o prefixo `collie/lane/` nem em um branch de cercado.
4. O git roda como o `LoopHost.git` roda hoje (`loopGit`: sem filtros perigosos, sandboxado quando o daemon sandboxa): **não chame `Process` solto**. Se o `LoopHost` precisa de um método novo para isso, acrescente com implementação padrão, sem quebrar os hosts existentes.
5. Nada no motor muda nesta tarefa.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneWorktreeTests.swift`

Em repositório git temporário (como `WorkLoopTests`): criar uma faixa a partir de um sha e ver o arquivo lá; dois `create` do mesmo trabalho/tarefa falham sem apagar o primeiro; `task` inválido (com `..`, barra, vazio, longo demais) é recusado antes do git; `remove` idempotente e apaga branch e diretório; `orphans`/`sweep` removem só as faixas de trabalhos que não estão ativos e **não** tocam em outros branches nem em outros worktrees (crie um worktree e um branch de cercado falsos e prove que sobrevivem); a faixa não aparece como mudança na árvore do repositório principal (`git status` limpo).
