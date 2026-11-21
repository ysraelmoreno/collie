# Estado do laço, Onda 3c: achados da revisão da 3b e menos turnos do Pastor

Relatório da revisão (leia o achado da sua tarefa): `rev-onda3b-report.md` (esta pasta). Veredito dela: não bloqueia a instalação; corrigir antes de usar `--parallel` e antes do push. Continua `onda3b.md`. Regras: as de `README.md` e `onda3-paralelismo.md`; `--parallel 1` segue idêntico; nenhum `sleep` novo; campos novos opcionais e tolerantes.

| # | Tarefa | Origem |
|---|---|---|
| M3c.1 | Criar e remover faixas em série; esperas dos testes canceláveis | achado 1 |
| M3c.2 | O Shepherd esperando não conta como trabalhando; o portão que deixa arquivo não para o laço | achados 2 e 3 |
| M3c.3 | Endurecer o perfil da faixa, o `remove`, o SIGKILL do portão e a marca | achados 4 e 5, nits |
| M3c.4 | `work run --notify end`: menos turnos do Pastor | medição de tokens (2026-11-21) |

O retry das suítes instáveis no `scripts/laco-check.sh` já foi feito pelo Pastor (fora do laço).
Verificação: `scripts/laco-check.sh M3c.n` (cumulativo).
