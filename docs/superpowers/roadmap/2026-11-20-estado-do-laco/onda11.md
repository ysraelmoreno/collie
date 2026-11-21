# Estado do laço, Onda 11: velocidade dos testes e do laço, e o app "Quadro" (kanban com conexão agêntica)

Origem: `aval-suite-report.md` (esta pasta), propostas P1, P4, P5, P6, P7 e a parte segura de P2/P3; e o pedido do dono (2026-11-21) de um app adotável, "um Trello com conexão agêntica", onde qualquer agente cria tarefa, move status, comenta, e **todo o progresso fica salvo em arquivo**.

Rodam em paralelo (`--parallel 3`, escopos que não se sobrepõem). Quem toca `scripts/laco-check.sh` é só a M11.4, depois das outras; as demais tarefas **não** passam por ele (evita conflito de integração entre faixas): cada uma traz o seu `--check` direto.

| # | Tarefa | Escopo | Depende de | Origem |
|---|---|---|---|---|
| M11.1 | `AskTests` fora do caminho crítico: relógio injetável nos limites do ask | `Sources/CollieDaemonKit/**/Ask*`, `Tests/**/Ask*` | | P1 |
| M11.2 | CI: cache de `.build`, timeout por shard e log da última suíte iniciada | `.github/workflows/ci.yml`, `scripts/ci/**` | | P4, P3, P2 (parte segura) |
| M11.3 | Build do agente com nome estável por laço, e limpeza das pastas `.build` velhas | `Sources/CollieDaemonKit/CollieOrientation.swift`, `scripts/dev/prune-builds.sh`, testes dela | | P5 |
| M11.4 | `laco-check.sh`: filtros validados, área declarada + fumaça, cumulativo só no portão final | `scripts/laco-check.sh`, `scripts/test-laco-check.sh` | M11.1, M11.2, M11.3 | P6, P7 |
| Q11.1 | Quadro: armazenamento (JSON de verdade, espelho `BOARD.md`, diário `events.jsonl`) | `Examples/apps/quadro/store.py`, `.../tests/test_store.py` | | pedido do dono |
| Q11.2 | Quadro: servidor HTTP loopback + SSE | `Examples/apps/quadro/server.py`, `.../tests/test_server.py` | Q11.1 | pedido do dono |
| Q11.3 | Quadro: UI do quadro (arrastar entre colunas, ao vivo) | `Examples/apps/quadro/ui/**` | | pedido do dono |
| Q11.4 | Quadro: contrato para agentes (`collie.json`), `run.sh`, README | `Examples/apps/quadro/collie.json`, `run.sh`, `README.md`, `docs/feature-map.md` | Q11.2, Q11.3 | pedido do dono |

Fora desta onda: a convenção genérica de check por projeto (o dono quer ver depois), P8 (lint de spec), P9, P10, P11. Depois do laço: o Pastor faz `collie app adopt quadro` (cartão de aprovação do dono) e roda o cumulativo completo uma vez.

Check de cada tarefa: `scripts/check-onda11.sh <m11-1..q11-4>` (os comandos das seções "Check" das tarefas são o que ele roda).

## Regras de todas as tarefas
As de `README.md` desta pasta. Mais:
- Repositório público: nenhum nome interno, caminho pessoal, token ou dado de usuário em código, teste, fixture ou doc.
- Sem `sleep` nem relógio de parede em teste Swift (continuations, relógio injetado); em teste Python, sem `time.sleep` para esperar o servidor: use evento/porta efêmera `0`.
- Nenhum arquivo novo fora do que a tarefa pede (o laço apaga o que não for rastreado).
- Nenhuma tarefa roda a suíte inteira: só `--filter` das suítes que mexeu.
- **Quadro: só biblioteca padrão do Python 3.9** (a máquina do dono tem 3.9.6; nada de `match`, nada de `X | Y` em tipo, `from __future__ import annotations` se usar anotações modernas). Sem dependências, sem `pip`, sem rede. Sem `innerHTML` na UI.
