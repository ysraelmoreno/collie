# Do PRD ao laço: PRD → plano → aprovação → `work run`

O Collie não conhece Jira, Linear nem GitHub. O PRD chega já em markdown; de onde veio é texto (`--origin`).

1. **PRD (dono):** `collie work prd add prd.md --origin "LIN-123" --terminal <Pastor>` guarda uma cópia imutável no
   trabalho ativo do Pastor (pasta do daemon, `work-loops/<trabalho>/prd/<sha256>.md`, 0444) e o sha256 no estado. Mesmo
   conteúdo de novo não muda nada; outro conteúdo exige `--replace`, e o anterior fica guardado. O hash e a origem aparecem
   no `work status`, nas notas do trabalho e no resumo do auto-land. Agentes leem com `collie work prd show` (também no MCP).
2. **Plano (Pastor):** a skill `factory-plan` (`docs/fabrica/skill/factory-plan/SKILL.md`) escreve o pacote, `waves.md` e
   `tasks/*.md` (modelo em `docs/fabrica/modelos/plano/`), e roda `collie work plan lint <pasta>` até passar. O linter
   recusa, com arquivo e linha: tarefa sem `check`/`area`, check que não roda nada, check que só faz grep/test -f/ls no
   arquivo da tarefa, `area` com `check`, cartão acima de 1500 caracteres, ciclo ou id desconhecido em `needs`, tarefa sem
   teste citado e erros do `waves.md`. Sai 1 quando recusa; `--json` dá as recusas e o hash.
3. **Aprovação (dono):** `collie work plan apply <pasta> --approve <sha256> --terminal <Pastor>`. Só com o linter verde e
   o hash igual ao do pacote agora (o dono confirma o que viu; mudou um byte, o hash muda). Cria as tarefas do trabalho
   ativo, com `needs` por onda (cada tarefa precisa das da onda anterior) e a spec apontando para o cartão. Não inicia o laço.
4. **`work run` (dono ou Pastor):** como sempre, com o cartão do app confirmando tarefas e limites. Num trabalho com PRD, o
   `work run` roda o linter de novo no pacote aplicado e recusa se ele não passa ou se o hash mudou depois da aprovação.

O que isto não faz: buscar o PRD em ferramenta externa, escrever código ou decidir por você o que entra; e não promete
nada de F4.
