# PRD B2: portão do laço

## Problema

Todo check de tarefa repete o mesmo final ("e o lint passa, e a arquitetura passa, e compila"). Isso: (1) gasta o
limite de 1500 caracteres do cartão de aprovação (`loopCardMax`), que hoje já limita uma onda a ~4 tarefas;
(2) deixa o dono revisar a mesma coisa N vezes; (3) mistura "a tarefa falhou" com "a base falhou" na razão da falha.

A palestra: o loop interno precisa ser confiável antes de ser automatizado; o portão é a parte do loop que não depende
da tarefa.

## Objetivo

`collie work run --gate "<comando>"`: um comando que roda depois do check de **cada** tarefa, nas mesmas condições
(worktree do cercado, sandbox do laço, env restrito, orçamento), aprovado uma vez no cartão.

## Não-objetivos

- Portão guardado no repo (`.collie/gates`): o agente do laço poderia editar o comando que o julga (anti-objetivo do
  design do laço). Fica no registro, como o check.
- Portão persistente por cercado. O Pastor passa de novo a cada `run`; se cansar, revisitar.
- Vários portões. Um comando; quem quer vários usa `&&`.

## Requisitos

1. `WorkLoopState` ganha `gate: String?`. `work run` aceita `--gate`; vazio ou só espaço é recusado.
2. Veredito: passa = check exit 0 **e** portão exit 0 **e** commit novo **e** nada rastreado sujo. O portão só roda se o
   check passou. Razões novas: `gate failed (exit n)`, `gate timed out`.
3. O portão usa o mesmo timeout do check (`checkTimeout`) e conta no orçamento.
4. Cartão: o portão aparece uma vez, depois dos limites, em «…» (mesma regra de caracteres proibidos das tarefas).
5. O prompt da tentativa mostra o portão junto com o check ("e depois este portão").
6. `work status`/painel mostram o portão do laço.
7. `/collie:loop` (texto em `LoopCommand.swift`) ensina: o que é comum a todas as tarefas vai no `--gate`.
   `docs/referencia.md` documenta.

## Medida de resultado

- Onda 3 deste roadmap roda com `--gate` e checks de tarefa < 150 caracteres cada.

## Tarefas

- B2.1 `--gate` no daemon e na CLI (`tasks/b2-1-gate.md`)
- B2.2 `/collie:loop` e referência (`tasks/b2-2-gate-docs.md`)
