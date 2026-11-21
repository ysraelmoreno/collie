# Estado do laço, Onda 3d: achados da revisão da 3c

Relatório (leia o achado da sua tarefa): `rev-onda3c-report.md` (esta pasta). Veredito: não bloqueia a instalação; corrigir antes do push. Continua `onda3c.md`. Regras: as de `README.md` e `onda3-paralelismo.md`; `--parallel 1` idêntico; **nenhum `sleep` nem relógio de parede em teste**; campos novos opcionais e tolerantes.

| # | Tarefa | Origem |
|---|---|---|
| M3d.1 | Um `work.wait` órfão não faz o starter passar por "só esperando" | achado 1 |
| M3d.2 | Testes sem relógio para os avisos e o ponta a ponta do Shepherd em `work wait` | achados 2 e 3 |
| M3d.3 | O lixo do portão não bloqueia a integração seguinte | achado 4 |

Verificação: `scripts/laco-check.sh M3d.n`.
