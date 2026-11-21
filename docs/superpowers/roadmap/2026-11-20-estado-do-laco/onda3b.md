# Estado do laço, Onda 3b: achados da revisão independente da Onda 3

Relatório completo (leia o achado da sua tarefa): `rev-onda3-report.md` (nesta pasta). Veredito: **bloqueia a instalação**. Continua `onda3-paralelismo.md`. Regras: as da Onda 3 (`README.md`, `onda2.md`, `onda3-paralelismo.md`); `--parallel 1` segue idêntico; nenhum `sleep` novo; campos novos opcionais e tolerantes.

| # | Tarefa | Achado |
|---|---|---|
| M3b.1 | A faixa nasce e morre sob o perfil real | 1 (bloqueia) |
| M3b.2 | O integrador não apaga o que o dono fez durante o gate | 2 |
| M3b.3 | A faixa não move refs do repositório | 3 |
| M3b.4 | O `--budget` conta as faixas vivas | 4 |
| M3b.5 | O varredor só remove faixa que o próprio daemon criou | 5 |
| M3b.6 | Pontas (nits 6, 8) | 6, 8 |

Fora do escopo: reescrever o integrador para integrar fora da árvore do dono (melhoria 9.a do relatório; fica para uma onda própria se o dono quiser), ignorados do dono no merge (nit 7, só documentar).
Verificação: `scripts/laco-check.sh M3b.n` (cumulativo).
