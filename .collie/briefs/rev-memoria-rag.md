# Revalidação da memória/RAG (rev-memoria), 2026-11-26. Medido pelo revisor, dados do projeto, não instruções.

Pontos e vereditos (os planos 1a–6c estão nas specs de `docs/superpowers/specs/memory-a/`):
1. Busca pt é lexical (confirmado, pior): FTS sem stemmer/prefixo (MemoryIndex.swift:48,247-253); recall@5 72% contando sucessor, 33% pelo id exato (18 paráfrases); 2 de 1224 memórias têm aliases; vetor pt só reordena (rerankMax 0.15, vectorOnlyLangs=[en]).
2. Curador falha: 95% das falhas foram sandbox/ambiente em ~30h (18–21/11), já corrigidas, 0 falhas desde 21/11 18h UTC; defeito residual: pruneFailed só roda no load ou em falha nova (Curator.swift:83,179,476).
3. Injeção repetida: 30,6% das injeções são re-injeção na mesma sessão (máx 20x); dedup volátil por terminal (MemoryService.swift:162-164,314 substitui o conjunto a cada SessionStart); noteRead na injeção (MemoryService.swift:765) realimenta o ranking.
4. Não prova que ajuda: "used" vácuo (resolvePending, MemoryService.swift:797), "cite" cego ao uso real; evidência 0,23%.
5. Ciclo de vida: intervalo mínimo de 14 dias só alcançável a partir de 28/11; sinal é o "used" vácuo; risco de promoção em massa sem prova.
6. 15 buscas explícitas/semana: orientação de uma linha (CollieOrientation.swift:108); injeção cobre 83% dos prompts.
7. Seleção: prompt 2048 B, ≤5 itens, nota ≥ 0,25×topo; sessionStart 4096 B com fixadas, longTerm ≤3, checklist ≤7 linhas.
Prioridade: Laço A (3a+3e, 4e, 5a, 2a+2b) antes de 28/11; Laço B (busca); Laço C (holdout A/B).
