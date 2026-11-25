# Revisão independente da F2, sétima rodada (2026-11-23)

Revisão curta de lógica e regressão (motor-concorrencia, opus) sobre o laço U e o modo parecer (A1, A2). **Sem blocker.** 3 de 4 anteriores corrigidos (o aberto é um nit coberto por defesa em profundidade). 1 major, 3 minors, 1 nit. JSON em `rev-f2g/`.

## Major
A cópia pelos blobs (U2) cria 2 processos git por arquivo (`config --show-scope` mais `cat-file blob`) por persona; num repositório de 1455 arquivos com 3 a 5 personas são milhares de processos, dezenas de segundos a minutos, sem prazo total e fora do orçamento do turno (o turno é medido ANTES). Conserto: UMA cópia por tentativa com um só `cat-file --batch`, um clone da cópia por revisor (clonefile/`cp -c`), e medir o turno depois do snapshot (`budgetOut` se cair abaixo do mínimo).

## Minors e nit
- Config global mudou durante a revisão substitui o resultado por mudo mesmo com veto confirmado: um órfão apaga o único dente do parecer. Conserto: manter o veto e só converter não-veto em mudo, com a nota.
- O teto de 64 MiB vale para toda chamada do `laneGit` (worktree, integração, diff) e o `BoundedProcess` guarda dois buffers: 128 MiB por chamada. Conserto: 1 MiB padrão, 64 MiB só no snapshot.
- O teste do U1 deixou de poder falhar: com o A1 a tentativa 1 passa, a 2 nunca roda. Conserto: tentativa 1 falha pelo check, planta o env, e a 2 deve ter revisores mudos com `reviewGlobalConfigRiskyNote`.
- Nit: caminhos não UTF-8 do `ls-tree` viram U+FFFD; dividir a saída por NUL em bytes.
