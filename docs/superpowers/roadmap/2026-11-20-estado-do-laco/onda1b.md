# Onda 1b: achados da revisão independente da Onda 1

Revisão (`rev-onda1`, 2026-11-20): **não bloqueia o merge**; o `attempt()` novo é equivalente ao antigo em todos os caminhos examinados; 118 testes passam. Os achados de robustez, que esta onda corrige **sem mudar nenhum veredito do laço**:

| # | Tarefa | Achado | Efeito |
|---|---|---|---|
| M1b.1 | Rede de segurança e decodificação tolerante | 1 e 2 | um evento fora de fase não deixa mais a tarefa presa em `inProgress`; um subcampo novo malformado não apaga mais o `loop` inteiro do trabalho |
| M1b.2 | Custo de escrita do diário | 3 | ~16 gravações por tentativa viram ~8; o diário dos trabalhos fechados é podado |
| M1b.3 | Pontas | 5, 7, 8 e 9 | `cancelled` chega ao disco no desligamento; `discarded` só quando há patch; `events: false` não é erro; o teste enfraquecido volta a provar a ordem das notas |

O achado 4 (cancelamento durante o check vira veredito) **muda comportamento**: vai na M2.2 (retomada), onde o cancelamento passa a ser tratado de ponta a ponta. Os nits 6 (nota-resumo duplica a nota longa) e a melhoria do campo morto `Facts.hasGate` ficam como estão (o resumo foi desenhado assim).

Regras: as de `README.md` (Onda 1). Verificação: `scripts/laco-check.sh M1b.n`.
