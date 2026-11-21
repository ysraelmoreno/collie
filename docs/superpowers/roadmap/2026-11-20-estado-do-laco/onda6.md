# Estado do laço, Onda 6: achados da revisão da Onda 5 (Trilho 2, 3d, T6.1)

Relatório (leia o achado da sua tarefa): `rev-onda5-report.md` (esta pasta). Veredito: não bloqueia a instalação, mas **dois defeitos tornam o Trilho 2 inútil na prática** (A1 o detalhe nunca abre; A2 a seção LAÇOS não acompanha) e dois são de motor (A3 apaga arquivo do dono por pathspec; A4 o resumo imutável perde eventos). Regras: as de `README.md`; `--parallel 1` idêntico; nenhum `sleep` nem relógio de parede em teste; campos novos opcionais e tolerantes. O app só usa `work.*`/`artifact.*`/`panel.*` do daemon (nada que um cliente remoto não possa).

| # | Tarefa | Origem |
|---|---|---|
| M6.1 | O detalhe do histórico abre de verdade | A1 (+ A8) |
| M6.2 | O feed de laços acompanha o trabalho certo | A2 |
| M6.3 | `git clean` do portão com caminhos literais e sem apagar o que o dono criou | A3 |
| M6.4 | O resumo imutável guarda a linha do tempo de um trabalho fechado com laço rodando | A4 |
| M6.5 | Pontas: aviso da adiada, orientação do `work wait`, modelo do transcript, mensagens do app | A5, A6, A7, A9 |

Verificação: `scripts/laco-check.sh M6.n` (cumulativo, agora com as suítes de UI).
