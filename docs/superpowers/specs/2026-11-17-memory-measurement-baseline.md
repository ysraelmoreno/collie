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

## A métrica nova (Leva 1): definições

`memory stats` ganha `usage.precision`, `byAgent.<agente>.precision` e `trends.{current,previous}.precision` (só a taxa). No painel: uma linha "Precisão" abaixo da Cobertura.

- **Unidade: id de memória, não prompt.** `addUse` conta por id; a cobertura já responde "prompts com hit".
- **`injected`**: ids injetados por relevância ao prompt (`injected` com `where = prompt`). Pull do Cursor (`memory.task`), início de sessão, foco, regras e retratações ficam fora: não geram pendência de uso.
- **`candidates`** (denominador): desses, os que podem ganhar uso (`LifecycleRules.eligible`: projeto, ativa, não fixada, não revisada). Gravado no evento de injeção (campo novo opcional `eligible`) quando há sessão. Sem isso a taxa ficaria abaixo de 100% mesmo com tudo usado, porque revisadas e fixadas nunca ganham uso.
- **`used`** (numerador): ids que o próximo prompt contou (evento novo `used`, com os ids que o `addUse` aceitou). Uso repetido no mesmo dia e sessão conta de novo aqui (é por injeção), embora o `usefulUses` do lifecycle não cresça.
- **`corrected`**: ids descartados porque o próximo prompt foi correção (`used` com `reason = correction`, `hits` = quantos estavam pendentes).
- **`unresolved`** = candidates − used − corrected: sessão terminou sem próximo prompt, marcação wrong/outdated da mesma sessão, ou ainda pendente. Conta como injeção sem uso.
- **`flags`**: marcações `--useful` explícitas, **fora** da taxa (podem apontar qualquer memória injetada, inclusive de início de sessão ou pull, que não estão no denominador).
- **`rate`** = used ÷ candidates; `nil` (painel: "–") quando não há candidato. Nunca 0/0.
- **Agente**: o uso acontece no próximo prompt **do mesmo terminal**, então o evento `used` leva o terminal e o log carimba o mesmo agente da injeção. Um agente sem hook de prompt (Cursor, Codex) tem `candidates` 0 e `rate` nil; o sinal dele são os `flags`. As marcações agora levam o terminal (antes `byAgent.useful` nunca achava o agente).
- **Bordas do período**: injeção e uso são contados pelo horário do próprio evento; um par que cruza a borda se separa (no máximo um prompt por borda e terminal).
- **Compatibilidade**: linhas antigas sem `eligible`/`used` contam como injetadas, nunca como candidatas. Daemon antigo + app novo: o painel mostra "o daemon instalado ainda não mede". Daemon antigo lendo log novo: a linha `used` é ignorada (decodificação falha, linha pulada).

## Fase 1 do item 2: uso com evidência (sombra)

Spec `2026-11-17-memory-useful-evidence-design.md`. Só medição: nenhuma regra de tier, prazo, índice, promoção ou
arquivamento lê o contador novo.

**Campos novos em `memory stats`** (aditivos; app e daemon de versões diferentes continuam funcionando, o painel mostra
"o daemon instalado ainda não mede"):

- `usage.precision.def = 1`: a definição acima, sem mudança no número. Qualquer mudança de definição sobe o `def`;
  janelas de `def` diferente não se comparam.
- `usage.evidence {def: 1, candidates, evidenced, rate, byKind}`, também em `byAgent.<agente>.evidence` e
  `trends.{current,previous}.evidence` (só a taxa).
  - `candidates`: o mesmo da precisão v1.
  - `evidenced`: dos ids que o próximo prompt contou (`used` v1), os que a resposta do turno anterior **citou** (id
    curto de 8 hex ou título normalizado com ≥ 3 palavras) ou que um `memory get` da sessão **leu** antes do prompt; cada
    id uma vez. Por construção `evidenced ≤ used`.
  - `rate` = evidenced ÷ candidates (nil sem candidata).
  - `byKind`: toda evidência do período por tipo: `cite` (citação), `get` (`memory get` de memória injetada na
    sessão), `flag` (`--useful`). `flag` fica **fora** da taxa, como os `flags` da v1: aponta qualquer memória injetada, não
    só as do prompt.
- O evento `used` ganha `evidenced`/`evidence` (paralelos). `cite` e `get` vão no `used` do próximo prompt; só `flag`
  emite um `used` próprio com `where = flag`, que a precisão v1 ignora (só conta o do prompt): o número v1 não muda.

**Nenhuma mudança de regra:** um `memory get` não conta uso; só marca o id, e a evidência é gravada no próximo prompt
sem correção, junto do uso implícito que já seria contado. `--useful` continua contando uso na hora, como antes deste
item.

**Como ler nos primeiros 14 dias:**

- Pré-requisito: um daemon com a Leva 1 **e** esta fase instalado; antes disso nada aparece. Anote a data de instalação.
- Esperado: precisão v1 perto de 90–99% (não discrimina); `usage.evidence.rate` entre ~3% e 15% (chute do spec, a
  confirmar); `byKind.get` e `byKind.flag` perto de zero.
- Só o Claude gera `cite` (único com Stop e pendência). Cursor e Codex: `candidates` 0, `rate` nil.
- Conferências: `evidenced ≤ precision.used` e `candidates` iguais nos dois blocos; em `lifecycle.json`,
  `evidencedUses ⊆ usefulUses`; nenhum tier mudou por causa disso.
- Eco do id (o agente repete `[abcd1234]` ao resumir a injeção) infla `cite`; a mitigação fica para a Fase 2, com os
  dados.
- Um reinício do daemon perde as citações do turno em curso (vivem só na memória do ator): no máximo um turno por
  terminal.
- Decisão da Fase 2 (regras exigirem evidência): só com ≥ 14 dias de sombra e por decisão do dono.
