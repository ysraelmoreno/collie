# Memória: linha de base das medições (antes da Leva 1)

Data: 2026-11-17, ~22:35 UTC. Código da branch: `1d290a2` (feat/doc-memory). Leitura só via CLI (`collie memory stats`, daemon em execução); nenhum arquivo do daemon foi lido direto.

## Versão medida

O daemon instalado **é mais antigo que esta branch**: `/Applications/Collie.app` 0.1.0 (build 1), binários `collie`/`collied` de 2026-11-15 18:26. `collie --version` e `collie status` não existem (`unknown command`). Ele ainda não tem as estatísticas por agente da Tarefa 8 (`7b4969e`): o relatório não traz `byAgent`. Os números abaixo são os do código de 15/11.

## Comandos

```
collie memory stats --since 24h
collie memory stats --since 7d    # o padrão
collie memory stats --since 30d
```

Sem `--project`/`--lot`: todo o escopo que o chamador vê. O log de eventos começa em 2026-10-28T17:28:43Z. Os números se movem durante a leitura (agentes ativos): 943 → 945 prompts em 7d entre duas chamadas.

## Números

| | 24h | 7d | 30d |
|---|---|---|---|
| prompts (injeções em `prompt` + noHit fora de `pull`) | 316 | 945 | 1763 |
| prompts com memória | 160 | 572 | 1070 |
| noHit (diferença) | 156 | 373 | 693 |
| **cobertura** | 50,6% | 60,5% | 60,7% |
| injeções (todos os `where`, soma de `injectionsPerDay`) | 191 | 797 | 1697 |
| tokens injetados (estimativa bytes ÷ 4) | 75 063 | 340 787 | 695 711 |
| buscas (`searched`) / resultados | 3 / 20 | 11 / 93 | 31 / 214 |
| correções / repetidas em 14 dias | 1 / 0 | 6 / 1 | 11 / 2 |
| flags useful / wrong / outdated | 0 / 0 / 1 | 0 / 0 / 1 | 0 / 0 / 1 |
| verify valid / invalid / deferred | 0 / 0 / 0 | 12 / 2 / 0 | 12 / 2 / 0 |
| promoções / rebaixamentos / provisórias arquivadas | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |

Estado atual dos tiers (não depende do período): **provisional 48, earned 182, longTerm 0**, contestadas abertas 1. Tendência semanal da cobertura: 58,4% (semana anterior) → 60,5%.

## Precisão: não mensurável hoje

O log não registra o uso útil (`addUse`): `resolvePending` grava só em `lifecycle.json`, sem evento. Por isso não há como calcular, com estes dados, "usos úteis ÷ memórias injetadas". O único indício é o estado: 182 de 230 memórias elegíveis (79%) já chegaram a `earned` (≥ 2 usos em ≥ 2 dias e ≥ 2 sessões) com **zero** flags `useful` — todo uso registrado é implícito (o próximo prompt não foi correção). A métrica nova (Leva 1) começa a contar só a partir dos eventos emitidos pelo daemon com o código novo; o histórico antigo continua sem precisão.

## O que o sandbox bloqueou

`~/Library/Application Support/Collie` (log `metrics/memory-*.jsonl` e `learning/lifecycle.json`): `Operation not permitted`. Uma reconstrução retroativa (casar injeções em `prompt` com `usefulUses` por dia e sessão) precisaria dessa leitura.
