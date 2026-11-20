# Onda 2b: achados da revisão independente da Onda 2

Revisão (`rev-onda2`, 2026-11-20, `fc718f4..HEAD`, relatório em `.collie/briefs/rev-onda2-report.md`): **bloqueia o merge** por um achado; o resto da onda foi examinado sem achado.

| # | Tarefa | Achado | Efeito |
|---|---|---|---|
| M2b.1 | A adoção não adota o que não é dela e nunca apaga o que não viu nascer | 1, 4, 5 | um `resumeFrom` velho não faz o laço julgar o commit de outra tarefa nem o do dono; uma adoção que falha **para e avisa** em vez de `reset --hard` |
| M2b.2 | Testes que dependiam do relógio | 2, 3 | o laço não queima tentativas por teste instável sob carga |

Regras: as de `README.md` e `onda2.md` (incluindo as "aprendidas na prática"). Verificação: `scripts/laco-check.sh M2b.n`.
