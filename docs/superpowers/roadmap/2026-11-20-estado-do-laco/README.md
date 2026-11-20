# Estado do laço: máquina explícita, motivos e diário (Onda 1)

Pedido do dono (2026-11-20): o Pastor depender do retorno de um terminal é instável (varia com o fluxo, o agente e o LLM). O laço deve ter um **estado explícito e durável**, que o Pastor lê, em vez de esperar texto. Esta é a **Onda 1** (observabilidade, sem mudar o que o laço decide). A **Onda 2** (o Pastor esperando mudança de estado, recuperação de queda, toque em fim de turno prematuro, reabrir tarefa) fica depois, quando a Onda 1 estiver instalada.

## O que o código é hoje (lido em 2026-11-20, `Sources/CollieDaemonKit/Work/WorkLoop.swift`)

A máquina já existe, implícita: tarefa `open → inProgress → done | deferred | open`; laço `running → stopped | finished`; `phase` (`agent`, `check`, `gate`). O veredito já é uma função pura (`verdict`). O estado é gravado a cada passo (`store.update`). O que falta:

1. **Saídas silenciosas.** `run()` sai com `break` sem dizer por quê: trabalho fechado/ausente/parado por fora ou Pastor não vivo (linhas ~68-69), `--max` (~72), `attempt()` devolvendo `false` (git falhou ~99, árvore suja ~105, cancelado ~144, trabalho fechado/Pastor sumiu ~155, outro terminal trabalhando ~257). Tudo termina como `state = .stopped` genérico; só alguns caminhos escrevem nota. É assim que o laço pode parar sem motivo visível (o caso das 00:13 de 2026-11-19 nunca foi explicado).
2. **Sem histórico de transições.** Só o último estado e notas de falha. Não dá para ver "o agente encerrou o turno por hook às 14:03, sem commit; o check rodou 7 s depois".
3. **Decisão da tentativa espalhada.** As regras pós-turno (committed, dirty, check, gate, moves, blocked, última tentativa, discard) estão inline em `attempt()` (~170 linhas misturando git, store e host), só testáveis dirigindo a tentativa inteira com um host falso.

## O que esta onda entrega

| # | Tarefa | Efeito |
|---|---|---|
| M1.1 | Motivo tipado de parada | todo laço que para diz por quê (`stopReason`), sempre com nota, no status e no aviso de fim |
| M1.2 | Diário de eventos do laço | anel de 100 eventos por laço, visível em `work status --events` |
| M1.3 | Decisão da tentativa pura | as regras pós-turno viram uma função pura com testes em tabela |
| M1.4 | Fases como máquina | `AttemptMachine.reduce(estado, evento) → (estado, efeitos)`; `attempt()` só interpreta os efeitos |

**Regra da onda: o comportamento do laço não muda.** Mesmos veredictos, mesmas tentativas, mesmo reset. Mudam o que fica registrado (motivo, diário) e a organização interna. Os testes existentes (`WorkLoopTests`, `WorkStatusTextTests`, `WorkStoreTests`) continuam passando sem afrouxar nenhuma expectativa de comportamento; só mudam os que olham a **forma** (por exemplo `attempt` devolver `Bool`).

A M1.4 é a de maior risco. Se a tentativa 3 falhar, ela pode ficar adiada: M1.1 a M1.3 já valem sozinhas.

## Fora do escopo (não fazer nesta onda)

`collie work wait`, retomada após queda do daemon, toque em fim de turno prematuro, reabrir/cancelar tarefa, mudar o prompt da tentativa, mudar o `Sources/CollieApp` além de ler campos novos (o app só decodifica; os campos novos são opcionais), qualquer mudança em `ask`/`inject`/`AskCoordinator`.

## Regras de todas as tarefas

Testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests`, nunca a suíte inteira. Os campos novos de `WorkLoopState` são **opcionais** e decodificam de arquivos antigos (`decodeIfPresent`/`try?` como `loop` já faz): um `work` gravado pelo daemon anterior continua abrindo. Sem dependência nova. Textos que o dono vê, em português. Commits convencionais, um por tarefa, só com os arquivos da tarefa; nada de push. Não tocar em `scripts/ci/`, `architecture-rules.txt` nem `lint-baseline.txt`; o lint do repo vale: sem `sleep` novo, `try!`, `as!`. `CollieCore` não importa AppKit/SwiftUI. O app só compila e é verificado por testes: não rode o app, não instale, não rode `bundle-app.sh`.
Verificação de cada tarefa: `scripts/laco-check.sh M1.n` (veja o script).

## Regras aprendidas na prática (valem para todas as ondas)

- **Nunca `await` (nem `try await`) dentro de `#expect`/`#require`**: leia o valor num `let` antes. Propriedade de actor lida dentro da expectativa é erro de compilação do alvo de testes, e derrubou duas tentativas na Onda 2.
- **Antes de commitar, rode as suítes novas uma a uma** (`--filter <Suíte>`) e leia `Test run with N tests`; um erro de compilação do alvo de testes derruba o check inteiro e a nota do laço mostra só o rabo da saída.
- Se a tarefa for grande, **commite cedo e em partes** (o código, depois os testes): sem commit novo a tentativa não conta.
- Ninguém, nem o agente, cria arquivo novo fora do que a tarefa pede: o laço apaga os arquivos não rastreados criados durante a tentativa.
