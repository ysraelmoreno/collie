# Revisão independente da F2, sexta rodada (2026-11-23)

Diff: laço V (`f4f2bff..5b6e1eaa`, 621 linhas). Só seguranca (opus). 4 de 6 anteriores corrigidos; **reject** com 2 blockers `closable`, 2 minors (1 `structural`). JSON em `rev-f2f/`.

## Blockers (consertos pequenos)
1. **Base do hash de `~/.claude.json` por tentativa:** o julgado planta o env numa tentativa sacrificada (revisores mudos, retry); na tentativa seguinte a base já contém o env plantado e os revisores nascem com ele (`PATH`/`ZDOTDIR` em caminho gravável fazem todo Bash do revisor rodar código do julgado). Conserto: base UMA vez, no início do laço, e calar o revisor se `env` tem qualquer chave ou `autoConnectIde` é true.
2. **`git replace` e commit-graph:** `GitRunner` não desliga replace objects; em laço de cercado o perfil abre `<common>/refs` e `<common>/objects` para escrita. O julgado faz `git replace C C'` e o `git archive`, o `ls-tree` do V1 e o diff do revisor leem C', enquanto o que é integrado é C: o revisor aprova código que não entra. Conserto: `GIT_NO_REPLACE_OBJECTS=1` e `-c core.commitGraph=false`.

## Minors
- (`closable`) A cópia é conferida só por nome contra o `ls-tree`; atributos (`working-tree-encoding`, `eol`, `export-subst`, filtro LFS que roda fora do sandbox) mudam o conteúdo. Conserto: conferir cada arquivo pelo oid (`hash-object --no-filters`) ou montar a cópia direto dos blobs (`cat-file --batch`).
- (`structural`) Hash só vê três instantes: órfão do julgado reparentado ao launchd grava o env em `~/.claude.json` depois do hash de lançamento e desfaz antes do final. Com `~/.claude.json` compartilhado e gravável por todo strict e processos do julgado vivos durante a revisão, comparação por hash não fecha. Só se fecha mudando o desenho (`CLAUDE_CONFIG_DIR` próprio com o login copiado, ou matar por perfil de sandbox).

## Opinião do revisor
"Os dois blockers são consertos pequenos, mas o resíduo estrutural não fecha por hash; justifica limitar o `--review` a um parecer que não aprova sozinho, ou só a laços em lane com revisor em `CLAUDE_CONFIG_DIR` próprio, até o isolamento mudar."
