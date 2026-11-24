# F5: entrada, do PRD em texto para ondas e tarefas

Roadmap F5. O daemon NÃO conhece Jira, Linear nem GitHub: recebe o PRD já em markdown, com a referência de origem como texto opaco.

## O que fazer
1. **`collie work prd add <arquivo.md> [--origin <texto>]`** (CLI, admin; MCP só leitura): guarda uma cópia IMUTÁVEL do PRD no trabalho ativo (pasta de estado do trabalho, `O_EXCL`, 0444, hash sha256 no estado; reaplicar o mesmo hash é idempotente, outro conteúdo exige `--replace` e guarda a anterior). `--origin` até 200 caracteres, sem controle, mostrado no resumo e na auditoria.
2. **Linter de spec** `collie work plan lint <dir>` (também chamado por `work run` se o trabalho tem PRD): lê `waves.md` e `tasks/*.md` e recusa, com arquivo e linha: tarefa sem `check` executável; check que só faz `grep`/`test -f`/`ls` no próprio arquivo que a tarefa cria; tarefa sem `--area` e sem `--check`; cartão de tarefa acima de 1500 caracteres; ciclo em `needs`; tarefa sem teste citado.
   Saída legível e código de saída 1; `--json`.
3. **Skill do Pastor** `docs/fabrica/skill/factory-plan/SKILL.md` (como `factory-init`): do PRD aprovado, gerar o rascunho de `waves.md` e `tasks/*.md` com `--check`, `--gate` e `--accept` (quando houver tela/serviço), dentro do limite de 1500 caracteres, rodar o linter até passar e pedir ao dono UMA aprovação do pacote. Modelo de `waves.md` e de tarefa em `docs/fabrica/modelos/`.
4. **`collie work plan apply <dir>`** (admin): cria as tarefas do trabalho a partir dos arquivos (com `needs` por onda), só depois de o linter passar e só com o hash do pacote aprovado igual ao dado no comando (`--approve <hash>`: o dono confirma o que viu). Nunca inicia o laço.
5. Documentação curta em `docs/fabrica/` (fluxo PRD → plano → aprovação → `work run`), sem prometer o que F4 ainda não faz.

## Testes
`PrdStoreTests` (imutável, idempotente, replace, origem), `PlanLintTests` (cada recusa com arquivo/linha; pacote bom passa), `PlanApplyTests` (hash errado recusa; needs por onda; nunca inicia o laço). Sem terminais reais.

Check: `scripts/check-autoland-loop.sh f5`. Commit ao final, só os arquivos da tarefa.
