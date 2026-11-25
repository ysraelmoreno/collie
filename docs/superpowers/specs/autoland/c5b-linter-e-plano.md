# C5b: minors do linter de plano e do `plan apply` (revisão do delta C3b/C4a)

Cada ponto com teste que FALHE sem a correção.
1. **Check que engole a falha.** `PlanLint.swift` (~210) só reconhece `|| true`, `|| :` e `; true`. Trate como "check sempre verde" (`check-trivial`) também: `|| echo ok`, `|| exit 0`, `; exit 0`, `| true`, `|| true # comentário`, `|| printf ...`; regra geral: depois de `||` ou `;` (ou `|`), um comando só de `trivial` (true, :, echo, printf, exit N) encerra o check, qualquer coisa antes dele não conta. Um check real (`swift test || scripts/check.sh`) continua válido.
2. **`cd x && grep -q y f`** passa hoje porque `cd` não é inspetor nem trivial: trate `cd` como neutro (ignore o pedaço) ao decidir se o check só inspeciona. E `diff <(swift run a) golden` (que roda código) NÃO é recusado.
3. **`work plan lint` falha aberto sem raiz.** `WorkPlanCommands.swift` (~187): `try? projectRoot(of: t)` vira nil e a cerca vira o próprio pacote; sem raiz do projeto o lint recusa ("não achei a raiz do projeto").
4. **Teste do `plan apply` com symlink.** `PlanApply.apply` e o `planApply` do router nunca rodam com symlink nem `root` nos testes; acrescente: cartão symlink e `tasks` symlink recusados pelo `plan apply` (não só pelo lint), e o `root` repassado a `apply`.

Check: `scripts/check-autoland-loop.sh c5b`. Commit ao final, só os arquivos da tarefa.
