# Estado do laço, Onda 9: achados da revisão das Ondas 7 e 8

Relatório (leia o achado da sua tarefa): `rev-onda78-report.md` (esta pasta). Veredito: não bloqueia a instalação; B1 e B2 entram no bundle (o dono precisa alcançar o histórico), os demais antes do push. Regras: as de `README.md`; `--parallel 1` idêntico; nenhum `sleep` nem relógio de parede em teste; o fake **aplica a regra real**.

| # | Tarefa | Origem |
|---|---|---|
| M9.1 | UI: o histórico alcançável sem laço rodando; falha de "Abrir no canvas" visível; ids do `ForEach`; resposta fora de ordem | B1, B2, B7, B8 |
| M9.2 | Daemon: `discard` lê nomes crus; histórico com só notas; `work stop` alcança laço de trabalho fechado; histórico antigo sem cercado | B3, B4, B5, B6 |

Verificação: `scripts/laco-check.sh M9.n`.
