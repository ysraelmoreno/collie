# M6.3 `git clean` do portão com caminhos literais e sem apagar o que o dono criou

Leia `onda6.md` e o **achado A3** de `rev-onda5-report.md`. Código: `Sources/CollieDaemonKit/Work/LaneIntegrator.swift` (~149 o comentário `ponytail`, ~182 `git clean -q -f -- <nomes>`, ~186 `hash-object --`, `gateMade`, `sweep`), `Tests/CollieDaemonKitTests/GateLeftoversTests.swift`.

## Problema
Depois de `--`, o git ainda lê cada nome como **pathspec** (glob `*?[]` e magia `:(…)`). Um arquivo literal `pages/[id].js` deixado pelo portão casa com `pages/i.js` e `pages/d.js` não rastreados do dono, e `git clean -f` os apaga. Um arquivo que o dono cria **durante** o portão conta como do portão e é apagado se não for mexido.

## Fazer
1. Todo comando do integrador que recebe nomes de arquivo usa **`git --literal-pathspecs`** (ou `:(literal)` por nome): `clean`, `hash-object`, `ls-files`, `status`, `add`/`rm` se houver. Prove com grep que nenhum git do integrador passa nome sem literal.
2. **Não apagar:** em vez de `git clean`, **mover** cada arquivo do portão para `<gitdir da worktree>/collie-gate-leftovers/<n>/` (quarentena dentro do `.git`, criada pelo daemon, com limite de 200 arquivos/5 MB e limpa no começo do próximo laço), só se continuam não rastreados e com o mesmo hash; um arquivo que o dono pode ter criado durante o portão é **movido, nunca apagado** (recuperável). A nota diz onde ficou.
3. Nenhum nome do portão com `..`, `/` inicial, `.git` ou barra invertida é tocado (valide antes de mover).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/GateCleanLiteralTests.swift`
Repositório temporário real: o portão deixa `pages/[id].js` e o dono tem `pages/i.js` e `pages/d.js` não rastreados ⇒ os do dono **sobrevivem**; nome `*`, `:(top)x`, `-rf`, nome com espaço e com newline ⇒ tratados como literais; o arquivo do portão é movido para a quarentena (conteúdo igual) e não apagado; um arquivo que o dono criou **durante** o portão e ficou inalterado ⇒ movido, nunca perdido; quarentena respeita o limite; `GateLeftoversTests` e as suítes de integração seguem verdes (ajuste só expectativas de "removido" para "movido para a quarentena", e diga no commit).
