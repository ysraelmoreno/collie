# Modelo do pacote de plano

Um pacote é uma pasta com `waves.md` e `tasks/<id>.md`. `collie work plan lint <pasta>` o lê; este modelo passa.

Campos do cartão (linhas `chave: valor` no começo da linha, fora de bloco de código; o resto é texto livre e vira a spec
da tarefa): `check` ou `area` (um dos dois), `accept`, `accept-timeout`, `needs`, `scope`, `evidence`, `agent`, `model`,
os mesmos de `collie work task add`. O título é a primeira linha `# `.

O `check` precisa rodar código (build, teste, script, comando do projeto). O linter corta o check em `&&`, `||`, `;` e `|`
e recusa (`check-trivial`) o que engole a falha (`|| true`, `|| :`, `; true`) e o check em que todo pedaço só inspeciona
arquivos (`grep`, `test`, `ls`, `cat`, `find`, `stat`, `head`, `tail`, `wc`, `diff`, `sed`, `awk`, `cmp`, `file`, `md5`,
`shasum`) ou sempre passa (`true`, `echo`, `printf`, `exit`). É uma heurística sobre as palavras, sem parser de shell:
`bash -c 'grep …'` ou um script que só faz grep passam. A revisão e o portão continuam sendo os juízes de verdade.

Links não são seguidos: `tasks`, `waves.md` ou um cartão que seja link, arquivo especial ou fora do projeto dão
`plan-unsafe-path`; um cartão que não abre dá `task-unreadable`.
