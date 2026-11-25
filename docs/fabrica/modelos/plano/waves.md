# Ondas: <título do PRD>

PRD: sha256 <os 12 primeiros do `collie work prd show`>
gate: scripts/ci/lint.sh

Cada `## Onda` lista as tarefas por id (o nome do cartão em `tasks/`, sem `.md`). Toda tarefa de uma onda depende de
todas as da onda anterior; dentro da onda, só o `needs:` do cartão as ordena. A linha `gate:` vira o `--gate` do
`collie work run` (o comando que vale para todas as tarefas: lint, build).

## Onda 1: o núcleo

- login-email

## Onda 2: a tela

- tela-login
