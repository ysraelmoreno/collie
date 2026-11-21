# Estado do laço, Onda 7: achados da revisão da Onda 6

Relatório (leia o achado da sua tarefa): `rev-onda6-report.md` (esta pasta). Veredito: não bloqueia a instalação; corrigir antes do push. Regras: as de `README.md`; `--parallel 1` idêntico; nenhum `sleep` nem relógio de parede em teste; campos novos opcionais e tolerantes. Em tarefa que fala com o daemon, o **fake deve aplicar a regra real** e a spec lista o cenário de ponta a ponta.

| # | Tarefa | Origem |
|---|---|---|
| M7.1 | A página do histórico não vaza para outro cercado e não acumula versões | A1 |
| M7.2 | Um laço por cercado vale também com trabalho fechado; `reset`/quarentena sem glob nem TOCTOU | A2, A5, A6 |
| M7.3 | Testes do feed sem `sleep`; o histórico recarrega no fim do laço de um trabalho fechado | A3, A4 (A7 se barato) |

Verificação: `scripts/laco-check.sh M7.n`.
