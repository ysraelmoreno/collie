# Aceite em runtime e entrada por PRD (preview)

Duas pontas do mesmo fluxo: a **entrada** (do PRD em texto até tarefas aprovadas) e o **aceite** (o resultado rodando
conta para o land). O motor do laço não conhece Jira, Linear nem GitHub: o PRD chega em markdown e a origem é texto
opaco. Nada aqui faz push (veja `docs/fabrica/auto-land.md`).

Estado: preview, testado com hosts falsos; a A7 (ponta a ponta) ainda não rodou. Detalhes de cada ponta:
`docs/fabrica/plano.md` e `docs/fabrica/aceite.md`.

## Entrada: PRD, plano, aprovação, `work run`

Todos os comandos agem no trabalho ativo do terminal (`--terminal <Pastor>` quando for o dono falando por ele).

### `work prd add | show`

```sh
collie work prd add prd.md --origin "LIN-123" --terminal <Pastor>
collie work prd show                      # também disponível ao agente (MCP: work_prd_show)
```

- `add` é só do dono (CLI; fora do MCP). Guarda uma cópia IMUTÁVEL do arquivo (até 1 MiB) na pasta de estado do trabalho
  (`work-loops/<trabalho>/prd/<sha256>.md`, 0444) e o sha256 no estado do trabalho.
- O mesmo conteúdo de novo não muda nada; outro conteúdo exige `--replace`, e o anterior continua guardado.
- `--origin`: até 200 caracteres, sem caracteres de controle; aparece no `work status`, nas notas e no resumo do auto-land.
- `show` (só leitura) imprime texto, sha256 e origem.

### `work plan lint | apply`

```sh
collie work plan lint docs/plano-x            # só leitura; imprime o sha256 do pacote; --json
collie work plan apply docs/plano-x --approve <sha256> --terminal <Pastor>
```

O pacote é uma pasta com `waves.md` e `tasks/*.md` (modelo em `docs/fabrica/modelos/plano/`; a skill `factory-plan`,
`docs/fabrica/skill/factory-plan/SKILL.md`, escreve o rascunho a partir do PRD).

- `lint` recusa, com arquivo e linha: tarefa sem `check` executável; check que só faz `grep`/`test -f`/`ls` no próprio
  arquivo da tarefa; tarefa sem `area` e sem `check`; `area` junto de `check`; cartão acima de 1500 caracteres; ciclo
  ou id desconhecido em `needs`; tarefa sem teste citado; erros do `waves.md`. Sai com código 1 quando recusa.
- `apply` é só do dono (CLI; fora do MCP). Só cria as tarefas com o linter verde E com `--approve` igual ao sha256
  do pacote naquele instante (o dono confirma o que viu; um byte muda o hash). Cada tarefa precisa das da onda
  anterior (`needs`) e a spec aponta para o cartão. **Nunca inicia o laço.**
- Num trabalho com PRD, o `work run` roda o linter de novo no pacote aplicado e recusa se ele não passa ou se o
  hash mudou depois da aprovação.

## Aceite: `work task add --accept`

O check julga o código; o aceite julga o **resultado rodando** (a tela abre, o serviço responde, o fluxo passa). É um
comando de shell, exit 0 = aceito, sem framework.

```sh
collie work task add "Tela de login" --spec docs/specs/login.md \
  --check "swift test --filter LoginTests" \
  --accept "scripts/accept/login.sh" --accept-timeout 900
```

- `--accept-timeout`: segundos, padrão 600, no máximo 1800.
- O comando fica no estado do trabalho, aprovado com a tarefa pelo dono; o agente não o recebe e o laço nunca o lê da
  worktree.
- Ordem na tentativa: check, portão, **aceite**, parecer. Roda na worktree da tentativa, sob o mesmo perfil de sandbox
  do check, depois que o agente foi dispensado. Check ou portão vermelho: o aceite não roda.
- Falhou: conta como falha de check; a saída (até 64 KB, limpa de segredos, cabeça e rabo) vai para a nota da próxima
  tentativa e o diário grava `acceptFailed` (`acceptStarted` e `acceptPassed` também são gravados).
- Se a tentativa alterou arquivo que o comando cita, é reprovada sem rodar o aceite (como no portão).
- No auto-land é a condição `landAcceptRed`: se qualquer tarefa tem `--accept`, o último aceite dela precisa ter passado
  na tentativa vencedora. Sem nenhum `--accept` no trabalho, o resumo diz "sem aceite em runtime".
- `factory.verification.scenarios` continua vazio no `factory doctor` (aviso): o aceite é por tarefa, não do perfil.

Exemplos de script (serviço HTTP, app do cercado, navegador, simulador) estão em `docs/fabrica/aceite.md`.

## Fluxo completo

1. Dono: `work prd add` do PRD aprovado.
2. Pastor: skill `factory-plan` escreve o pacote e roda `work plan lint` até passar.
3. Dono: lê o pacote e roda `work plan apply --approve <sha256>`.
4. Dono (cartão do app) ou Pastor: `work run --auto-land` (veja `auto-land.md`) confirma tarefas, checks, `--accept`
   e limites. O resumo fica em `work-loops/<trabalho>/autoland/`.
5. Dono: revisa o resumo e dá o push, se quiser. O Collie não o faz.
