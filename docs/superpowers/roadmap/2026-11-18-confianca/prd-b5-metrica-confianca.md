# PRD B5: métrica de confiança do laço

## Problema

A palestra mede confiança por resultado: 11 000 PRs/mês com 0,5% de revert. O Collie não mede nada do laço além do
estado de cada tarefa. Sem número, não há base para decidir quando confiar mais (laços maiores, menos revisão) ou menos.

## Objetivo

O resumo do trabalho mostra, para os laços dele: taxa de aprovação na 1ª tentativa, média de tentativas, adiadas, tempo
total; e, depois, quantos commits aprovados pelo laço foram revertidos.

## Não-objetivos

- Painel ou dashboard novo. Entra no resumo e no `work status` existentes.
- Métrica entre trabalhos (histórico global). Revisitar quando houver 10+ laços.
- Custo em tokens (o laço não tem esse dado).

## Requisitos

1. **B5.1:** função pura sobre o `Work` (tarefas com `tries`, `state`, `evidence`): `firstTry` (feitas com `tries == 1`),
   `done`, `deferred`, `meanTries`, `seconds` (soma de `evidence.seconds`). Aparece no `WorkSummary` e numa linha do
   `work status` de um trabalho com laço: `laço: 5/6 feitas · 4 na 1ª · 1 adiada · média 1,4 tentativas · 2h10`.
2. **B5.2:** revertidos: para cada commit em `evidence.commits`, procura no histórico do branch atual um commit com
   `This reverts commit <sha completo>` (resolver o short sha com `git rev-parse`). Mostra `n revertidos` na mesma
   linha. Roda só quando o resumo é pedido (não no caminho quente), com git sob o mesmo cuidado do laço (filtros do
   repo desligados).

## Medida de resultado

- Depois das ondas 1–4: o dono tem os números das 4 ondas lado a lado e usa para decidir o tamanho da onda 5.

## Tarefas

- B5.1 números do laço (`tasks/b5-1-loop-stats.md`)
- B5.2 revertidos (`tasks/b5-2-reverts.md`)
