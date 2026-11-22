# M11.4 `laco-check.sh`: filtros validados, área declarada + fumaça, cumulativo só no portão final

Leia `onda11.md` e P6, P7 de `aval-suite-report.md`. Medida: cada check roda 72 filtros (~3,9 min), a maioria sem relação com a tarefa; nomes colados na lista já geraram falso negativo silencioso duas vezes. Código: `scripts/laco-check.sh`. **Só esta tarefa edita o arquivo** (as M11.1 a M11.3 já terminaram: leia o que elas trouxeram).

## Fazer
1. **Filtros validados:** antes de rodar, confira cada nome da lista contra `swift test list --skip-build` (ou, sem build, `git grep -E "(struct|class|actor) <nome>\b" Tests/`); nome que não casa **nenhuma** suíte = erro claro (`filtro sem suíte: X`), exit ≠ 0. Ancore o filtro (`\.Nome/`) para `AskTests` não casar `RemoteAskTests`.
2. **Área declarada + fumaça:** cada caso `Mx.y)` passa a poder declarar `area=(Suíte1 Suíte2 …)`. O check roda: o arquivo exigido (`need`) + a **área** da tarefa + a **fumaça** fixa (`WorkLoopTests AttemptMachineTests WorkStoreTests LoopJournalTests CommandsTests`). Caso **sem** `area` declarada continua rodando o cumulativo inteiro (comportamento de hoje): nenhuma tarefa antiga perde cobertura. A área é **declarada no `case`, nunca inferida do diff**.
3. **Cumulativo só no portão final:** `scripts/laco-check.sh --full` (ou `LACO_FULL=1`) roda a lista inteira de uma vez; é o que o Pastor roda no fim da onda e antes do merge. O retry de uma vez das suítes que falharam continua, mas **imprime** quais repetiu e quanto tempo gastou.
4. Mantenha a nota curta da falha (rabo da saída, nomes dos testes que falharam, resumo).
5. Acrescente os casos M11.1 a M11.3 (arquivos de teste novos), com a área de cada uma.

## Testes
`scripts/test-laco-check.sh` (novo, bash, com um `swift` falso no `PATH` e um `Tests/` temporário): nome inexistente na lista falha com a mensagem; nomes colados falham; um caso com `area` roda só área + fumaça (confira os `--filter` passados ao `swift` falso); um caso sem `area` roda tudo; `--full` roda tudo; o fake aplica a regra real (não aceita qualquer filtro).

## Check
`bash -n scripts/laco-check.sh && scripts/test-laco-check.sh && scripts/ci/lint.sh && scripts/ci/check-architecture.sh`.
