# Design: fields (worktree própria para um agente convocado)

Data: 2026-11-24. Estado: aprovado pelo dono em 2026-11-24. Decidido pelo dono na conversa: `summon --field` avulso; não é o
padrão; pode virar padrão do projeto pelo `collie-work.json`; o trabalho volta sozinho quando um juiz passou, senão
espera o Pastor.

## Intenção

Delegar em paralelo na mesma worktree do cercado travou em 2026-11-24: builds Swift de 4 a 10 min numa fila única
(`lockf`), um agente salvando no meio do build do outro ("modified during the build"), cópias limpas compilando do zero.
Um **field** dá a um agente convocado a própria worktree, cortada do HEAD do cercado, com o cache de build já quente, e
traz o trabalho de volta pelo mesmo integrador das faixas do laço.

## Objetivos

1. `collie summon <nome> --field` cria o field e lança o agente nele. Sem `--field`, nada muda.
2. O agente trabalha e commita no branch do field; o build dele não disputa a fila do cercado.
3. **Volta com juiz:** um `collie ask <agente> … --check "<cmd>"` (C1) que passa para um agente em field leva o field
   ao integrador: merge no branch do cercado, portão de novo na árvore integrada; conflito ou portão quebrado → desfeito,
   vira patch, o field continua.
4. **Sem juiz:** o field fica "pronto para integrar"; o Pastor roda `collie field land <nome>` (mesmo integrador) ou
   `collie field drop <nome>`.
5. `collie-work.json` pode tornar `--field` o padrão do projeto e dizer o que clonar para aquecer o build.

## Não-objetivos

- Abrir um épico em fields automaticamente (lista de tarefas → um field cada). Fica para depois, por cima deste.
- Field como cercado: não aparece como cercado no app, não tem `paddock land`, não tem status próprio.
- Field para terminal livre (sem sandbox) ou para shell.

## Anti-objetivos

- Um field integrar trabalho que nenhum juiz aprovou sem o Pastor pedir.
- Um field mexer no branch do cercado, em `main` ou no de outro field por outro caminho que não o integrador.
- Perder trabalho: dispensar o agente de um field não integrado apaga o trabalho.

## O que já existe

- **Faixas do laço** (`Sources/CollieDaemonKit/Work/LaneWorktree.swift`): worktree em `<repo>/.collie/paddocks/lane-…`,
  branch `collie/lane/…`, criada e removida pelo git do daemon (`LaneGitQueue`), fora do `git status` do principal,
  sandbox estrito com a faixa como projeto; a faixa só grava objetos e o próprio branch.
- **Integrador** (`LaneIntegrator.integrate(_:title:attempt:tries:gate:gateTimeout:)`): merge `--no-ff` no branch do
  cercado, um por vez, portão na árvore integrada, desfaz e gera patch no conflito.
- **`summon(_:by:lane:)`** (`ShepherdCommands.swift`) já lança um agente numa faixa (só o laço usa).
- **`collie-work.json`** (`ProjectWorkConfig`): `gate`, `precheck`, `smoke`, `full`, `areas`; lido do commit no HEAD;
  chave desconhecida vira aviso.
- **`ask --check`** (C1, `84437a90`) e check vermelho antes (C2, `b8e93554`).

## Abordagens

- **A. Field = faixa aberta pelo `summon` (escolhida).** Reusa worktree, sandbox, git restrito e integrador. Código novo:
  o comando, o registro do field, o gatilho de volta e o aquecimento.
- **B. Um cercado por agente.** Já existe, mas é pesado (registro, app, `paddock land` só do criador) e foi o que o dono
  pediu para não usar por padrão (memória "delegate-same-paddock").
- **C. Worktree feita pelo próprio agente (`git worktree add`).** O que os workers fizeram hoje para verificar. Sem
  sandbox próprio, sem integrador, sem limpeza garantida. Descartada.

## Como funciona

### Comandos

```
collie summon <nome> --field [--prompt …]        # cria o field <nome> (mesmo nome do agente) e lança o agente nele
collie summon <nome> --no-field                  # quando o collie-work.json torna field o padrão
collie field list                                # campos do cercado: agente, branch, base, commits, estado
collie field land <nome>                         # integrador (Pastor que convocou)
collie field drop <nome> [--keep-branch]         # remove a worktree; sem --keep-branch, guarda patch e apaga o branch
```

Só o Pastor que convocou o agente faz `land`/`drop` (ou o app). `--field` exige sandbox (como `--parallel` > 1).

### Registro

`TerminalRecord.field: FieldRef?` (`name`, `branch` `collie/field/<nome>`, `base` sha, `path`, `state`
`working|ready|landing|landed|conflict`). Fica no workspace para sobreviver a reinício do daemon; a worktree é achada pelo
`path`, conferida por `LaneWorktree` (`ownsPath`).

### Volta

- `ask --check` que **passa** para um agente com `field` → `land` automático com o portão do `collie-work.json`
  (`gate`; sem gate, só o merge). O resultado do ask ganha `field: {landed: Bool, reason?}`.
- `ask` sem check, ou check que falhou → nada; o field segue `working`.
- Agente encerra o turno com commits novos e sem check → `ready` (aviso ao Pastor uma vez:
  `[collie] field <nome> pronto para integrar: collie field land <nome>`).
- `land` com conflito ou portão quebrado → `conflict`; patch em `<raiz>/fields/<nome>-<n>.patch`; o agente recebe uma
  linha com o motivo; o field continua e pode tentar de novo.
- Depois de `landed`, o field é **rebaseado** no HEAD novo do cercado (o próximo trabalho do mesmo agente parte do que
  já entrou) ou, se o rebase conflita, fica `conflict` com o motivo.

### Dispensa

`dismiss` (ou "Encerrar ramo") de um agente com field não integrado: a worktree sai, o branch fica
(`collie/field/<nome>`) e o Pastor recebe a linha com o branch. Nada se perde; `field drop` limpa de vez.

### Aquecimento

`collie-work.json`:

```json
{ "version": 1, "fields": { "default": false, "warm": [".build"], "max": 4 } }
```

- `warm`: caminhos relativos (sem `..`, dentro do repositório) clonados da worktree do cercado para o field na criação
  com clone APFS (`clonefile`, o `cp -c`): instantâneo, sem dobrar disco.
- `default: true`: `summon` sem flag usa field; `--no-field` desliga.
- `max`: fields vivos por cercado (1 a 8, padrão 4).

### Orientação

Um agente em field recebe uma linha a mais (dentro do limite de 1500): "Você está no field <nome> (branch …): commite
aqui; o Pastor integra." O Pastor aprende `summon --field` e `field land|drop` só se couber.

## Decisões minhas (o dono pode vetar)

1. O field tem o mesmo nome do agente: um agente, um field, sem ambiguidade nos comandos.
2. `ask --check` que passa integra sozinho mesmo sem `gate` no projeto (o check é o juiz); com `gate`, os dois.
3. Depois de integrar, rebase do field no HEAD novo, para o agente continuar sem divergir.
4. Dispensar não apaga o branch de um field não integrado.
5. `collie-work.json` é conteúdo do repositório (um agente pode escrever): `fields.default` só aumenta isolamento, e
   `warm` só aceita caminhos dentro do repositório; por isso não pede aprovação do dono.

## O que fica para quem constrói

- O formato da linha de `field list`.
- Onde o `FieldRef` mora (no `TerminalRecord` ou num mapa do workspace), desde que sobreviva a reinício.
- Se o rebase pós-integração usa o git restrito das faixas ou um caminho novo do daemon.

## Medida

Repetir a onda 1 do roadmap de qualidade do Cursor (7 PRDs, 4 em paralelo) com `--field` e `warm: [".build"]`: nenhum
"modified during the build", nenhuma cópia limpa feita por agente, tempo total menor que o de 2026-11-24.
