# Estado do laço, Onda 10: contexto compartilhado com ciclo de vida e menos tentativas queimadas

Origem: `aval-lacos-report.md` (esta pasta, cópia do relatório do analista), propostas P2, P3, P5, P6 e a decisão do dono de **não** mexer no ambiente dos agentes (P1 descartada: o agente precisa das ferramentas MCP) e de **enxugar o contexto compartilhado**, com um ciclo de vida.

Dados medidos (`collie memory stats`, 229 sessões): o Collie injetou ~0,95 M de tokens de memória em todo o período, ~4 mil por sessão. O que pesa é o **contexto do Pastor** (40% do cercado, 86% cache lido, contexto até 690 mil) e as **tentativas queimadas** (6 de 6 falhas pós-Onda 5 foram erro de compilação). Já existe um livro de injeção por sessão (`MemoryService.injected`: o mesmo id não volta na sessão); o que falta é o ciclo de vida do contexto do Pastor, os duplicados semânticos e a rede de segurança do turno.

Regras: as de `README.md`; `--parallel 1` idêntico; nenhum `sleep` nem relógio de parede em teste; campos novos opcionais e tolerantes; o fake **aplica a regra real**; nunca ler nem citar o conteúdo de um transcript (só números e tamanhos).

| # | Tarefa | Origem |
|---|---|---|
| M10.1 | Ciclo de vida do contexto do Pastor: medir o contexto real, avisar por tokens e deixar uma passagem de turno pronta | P3 |
| M10.2 | Rede de segurança do turno: regra no prompt da tentativa e pré-check na mesma sessão | P5, P2 |
| M10.3 | Tokens por tentativa no resumo imutável e `work usage` para trabalho fechado | P6 |
| M10.4 | Memórias quase duplicadas não entram juntas na injeção | medida: 5 armadilhas do mesmo assunto na mesma sessão |
| M10.5 | O botão de tela cheia do terminal não responde no canvas | pedido do dono (2026-11-21) |

Fora desta onda (esperam o relatório da suíte de testes): P4 (check por área), P8 (lint de spec). P7 (modelo por papel) é só configuração: `loopModel` nas Preferências.

Verificação: `scripts/laco-check.sh M10.n`.
