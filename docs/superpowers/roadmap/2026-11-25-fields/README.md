# Plano: fields (worktree própria para um agente convocado)

> **Para quem executa:** cada PRD é uma tarefa num terminal convocado pelo Pastor. Rode o check do seu PRD **uma vez,
> no fim**, dentro de `lockf -k .collie/build.lock`; lint e arquitetura uma vez, junto. Commit só com pathspec
> (`git commit -m … -- <arquivos>`): o índice da worktree é de todos.

**Objetivo:** `collie summon <nome> --field` dá ao agente a própria worktree (build próprio; o primeiro é frio) e traz o trabalho de
volta pelo integrador das faixas: sozinho quando um `ask --check` passou, pelo Pastor (`field land`) sem juiz.

**Arquitetura:** o field é uma faixa com formato próprio (`field-<nome>`, `collie/field/<nome>`), criada e removida pelo
git restrito do daemon (`LaneWorktree`), com o sandbox estrito da faixa; um integrador por cercado (fila FIFO única para
fields e laço); estado no `TerminalRecord`.

**Tecnologia:** Swift 6, git pelo `LoopHost.laneGit`.

**Spec:** `docs/superpowers/specs/2026-11-24-fields-design.md` (aprovado em 2026-11-24, com as respostas à revisão).
Leia inteiro antes do seu PRD.

## Restrições globais

- Sem `--field`, `summon` não muda (nem código de caminho, nem orientação).
- Field: `<repo>/.collie/paddocks/field-<nome>`, branch `collie/field/<nome>`, marcador `field <terminal uuid>`.
- `orphans`/`sweep` nunca tocam em `field-`.
- Field e `work run --parallel > 1` não convivem no mesmo cercado.
- `collie-work.json` dos fields é lido do HEAD do cercado (`WorkConfigFile.read(base:)`), nunca da árvore.
- `fields.max`: 1 a 8, padrão 4. Sem `warm` (F0: clonar `.build` falha).
- Patches em `<raiz>/fields/`, arquivos 0600.
- Textos ao agente/usuário em pt-BR.
- Testes só `swift test --disable-sandbox --filter <Suite>`; nunca a suíte inteira.

## Foco de revisão

1. **Nome de field com `/`, `..`, espaço ou maiúscula** (vem do nome do agente): recusado antes de qualquer git (F2).
2. **Daemon reinicia com field vivo:** o field volta pelo `TerminalRecord.field` e pelo `path`; nada órfão apagado (F2, F4).
3. **Dois `land` do mesmo field ao mesmo tempo** (ask passou + Pastor rodou `field land`): um integra, o outro recebe
   "já integrando" (F3).
4. **Cercado com o próprio Pastor editando sem commitar:** o land espera; depois de 10 min, aviso ao Pastor, nada
   perdido (F3).
5. **Dispensa no meio de um land:** o land termina ou desfaz; a worktree só sai depois (F4).

## PRDs e ondas

| Onda | PRD | O quê | Depende de |
|---|---|---|---|
| 0 | [F0](prd-f0-spike-warm.md) | spike: `.build` clonado? **Feito, 5c1589d0: não; `warm` sai** | — |
| 1 | [F1](prd-f1-config.md) | `collie-work.json`: `fields.default/max` | — |
| 1 | [F2](prd-f2-worktree.md) | `LaneWorktree` com formato de field; guardas | — |
| 2 | [F3](prd-f3-integrador.md) | um integrador por cercado; land de field; patch; fila espera o cercado | F2 |
| 3 | [F4](prd-f4-comandos.md) | `summon --field/--no-field`, `field list/land/drop`, dispensa, orientação, `TerminalRecord.field` | F1, F2, F3 |
| 4 | [F5](prd-f5-volta-automatica.md) | `ask --check` que passa integra; "pronto para integrar"; rebase depois | F4 |

F1 e F2 tocam arquivos diferentes (F1: `ProjectWorkConfig.swift`; F2: `LaneWorktree.swift`) e rodam em paralelo.

## Medida

Repetir a onda 1 do roadmap de qualidade do Cursor (4 PRDs em paralelo) com `--field`: nenhum "modified during the
build", nenhuma worktree feita por agente, tempo total menor que o de 2026-11-24.
