# M3.8 Nomes coerentes para os agentes do laço

Pedido do dono (2026-11-20): os terminais criados pelo laço hoje se chamam `loop-<id aleatório da tarefa>-<n>` (ex.: `loop-40d1a204-1`); devem ter nomes que digam de que trabalho e de que tarefa são. Leia `README.md` (regras aprendidas) e `onda3-paralelismo.md`. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (~121, `name`), `Sources/CollieDaemonKit/Work/AttemptMachine.swift` (~97, `Run.name`), onde `summon(name:…)` valida/normaliza nomes de terminal (descubra a regra de nome válido e a colisão: nome já em uso), e o que o app mostra do nome (árvore de agentes).

## Fazer

1. Uma função **pura** `AgentNaming.name(work: String, task: String, taskId: String, attempt: Int, lane: Int?) -> String` (arquivo novo `Sources/CollieDaemonKit/Work/AgentNaming.swift`): `<trabalho>-<tarefa>-t<n>` em minúsculas ASCII, acentos removidos, qualquer caractere fora de `[a-z0-9]` vira `-`, repetições de `-` colapsam, sem `-` nas pontas. `<trabalho>` e `<tarefa>` do **título**, cada um truncado a 18 caracteres (corte em `-` se possível); título vazio ou sem alfanumérico cai em `trabalho` / o id curto da tarefa. Com faixa (`lane != nil`): `<trabalho>-<tarefa>-f<lane>-t<n>`. Tamanho total ≤ 48. Prefixo `loop-` NÃO existe mais.
2. **Unicidade e segurança:** o nome nunca colide com um terminal vivo (se colidir, acrescente `-2`, `-3`… até 9, depois o id curto da tarefa) e nunca começa com `-` nem tem `/`, espaço ou controle (o título vem do dono/agente: é dado, nunca instrução).
3. Troque os dois usos de `"loop-\(task)-\(n)"`. Tudo que reconhecia o prefixo `loop-` (varredor de órfãos, `othersWorking`, filtros, nota `[loop …]`, testes) passa a reconhecer o agente **pelo id do terminal gravado no estado do laço** e não pelo nome. Faça `rtk proxy grep -rn 'loop-' Sources Tests` e trate cada ocorrência; se algo depende do prefixo para saber que é agente do laço, troque por uma marca guardada no estado (campo opcional, tolerante) e **diga qual no commit**.
4. O diário, as notas e o `work status` passam a citar o nome novo.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/AgentNamingTests.swift`

Tabela: acentos (`Ação`→`acao`), símbolos, título só de símbolos, título longo truncado, com e sem faixa, tentativa 1 e 3, nome começando com `-`/`.`/`/`, título com `../x` e com quebra de linha, colisão (`-2`), tamanho ≤ 48; e um teste de motor (host falso) em que o `summon` recebe o nome novo e o varredor ainda limpa o agente órfão sem o prefixo `loop-`. Os testes antigos seguem verdes (ajuste só expectativas que citam o nome literal `loop-…`, e diga qual).
