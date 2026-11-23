# Revisão independente da F2 (revisão por personas no laço), 2026-11-22

Diff revisado: `e87e63b..7428e05` (R1 a R5, 22 arquivos, +1.336 linhas; 1.858 linhas de patch). Revisores: 5 terminais novos, um por persona (primeiro uso das
personas, ainda de forma manual), cada um com o diff, os specs R1 a R5, o PRD e o contrato. Veredito agregado: **recusado, não instalar**. JSONs em `rev-f2/`.

| Persona (modelo) | Veredito | blocker | major | minor | nit |
|---|---|---|---|---|---|
| motor-concorrencia (opus) | reject | 1 | 3 | 3 | 0 |
| seguranca (opus) | reject | 0 | 2 | 2 | 0 |
| testes (sonnet) | reject | 0 | 2 | 4 | 1 |
| correcao (sonnet) | reject | 0 | 2 | 5 | 0 |
| simplicidade (haiku) | approve | 0 | 0 | 4 | 3 |

## O que bloqueia (confirmado no código antes de agir)
1. **BLOCKER: o revisor nasce dentro da worktree do laço.** `summonReviewer` (WorkLoopCommands.swift:730) reusa o `summon` de quem trabalha: o revisor lê o CLAUDE.md, AGENTS.md,
   `.claude/settings.json` e os hooks que o agente julgado commitou, e roda com o sandbox que ESCREVE na worktree. Quebra o anti-objetivo central do PRD (quem trabalha não influencia quem o julga).
2. **MAJOR: nada confere a árvore depois da revisão.** O revisor roda depois do settle; se editar ou commitar (por engano ou por injeção vinda do diff), nenhum check, gate ou `othersWorking` pega.
3. **MAJOR: o veredito é lido da tela do terminal** (`askText` devolve a tela na fonte `.idle`, que pode ecoar o prompt com o diff e os assuntos de commit). Um agente que planta
   `{"verdict":"approve",...}` no diff ganha o approve sempre que o revisor responde sem JSON. Falta um nonce por revisão e delimitadores com aviso de "dado não confiável".
4. **MAJOR: cancelar durante a revisão vira recusa falsa.** `judges()` (WorkLoop.swift:352) não inclui `.reviewDone`; as personas ficam mudas, o laço grava `reviewRejects += 1` e uma nota
   por uma recusa que nunca houve, e isso sobrevive ao `uncount`.
5. **MAJOR: `reviewRejects` só zera na aprovação** (WorkLoop.swift:527): reabrir a tarefa, adiar, ou uma falha de check entre duas recusas ainda contam como "seguidas".
6. **MAJOR (testes): o teste de que o revisor não bloqueia o laço não pode falhar** (o fake já dispensou o revisor quando `othersWorking` é chamado) e não há teste do eco do prompt com approve plantado.

## Minor relevantes
Orçamento esgotado contado como recusa; revisor sem marca durante o boot; revisores vazam se o daemon cai (`loopReviewers` só em memória); evidência com palavras de quem trabalhou; spec ausente no
commit base cai no título em silêncio; sem checagem do catálogo de personas no lançamento do `--review`; persona/spec editados só chamam a correcao (rotear segurança); buracos de teste (prazo estourado,
sem personas no base, fixture de roteamento que já divergiu das personas reais).

## O que a revisão ensinou sobre as personas
Os 5 devolveram JSON válido e acharam algo que os checks do laço (compilar, testes da própria tarefa, lint) não podiam achar, incluindo um blocker. Falhas do desenho: (a) "linha do diff" é ambíguo (um revisor usou o
número de linha do patch: `WorkLoopReview.swift:699`, arquivo de 129 linhas); (b) a mesma falha apareceu em 2 a 3 personas, o que confirma o achado mas pede deduplicação no agregador; (c) o haiku (`simplicidade`) fez só `minor` e `nit`, como mandado.
