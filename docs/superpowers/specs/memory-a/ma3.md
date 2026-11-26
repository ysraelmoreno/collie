# ma3: earned exige evidência

Laço A da revalidação da memória (`.collie/briefs/rev-memoria-rag.md`, ponto 5; leia). Depende de ma2. Check: `scripts/check-memory-a.sh ma3` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- **5a.** `tier` (LifecycleRules.swift:54-60): provisional → earned passa a exigir, além de 2 usos em 2 dias e 2 sessões distintos, **pelo menos 1 uso com evidência** (cite, `memory get`, `flag --useful`), gravando `earnedBy: "evidence"` (o campo existe e hoje nunca é escrito: LifecycleStore.swift:28-30). Uso implícito apenas fica provisional. Sem contestação aberta nem flag wrong/outdated, como hoje.
- Quem já é earned hoje continua earned (sem rebaixar em massa); a regra vale para novas promoções. Anote em `Resultado` quantos dos earned atuais não teriam evidência (só se der para medir em teste; não leia `lifecycle.json` real).
- O candidato a longTerm (`promotionCandidate`, :62-68) continua exigindo tier não provisório; documente que a promoção em massa por "uso vácuo" fica barrada por esta regra.
## Critérios de aceite (testes em `LifecycleEarnedEvidenceTests`, ≥ 6)
- 2 usos implícitos em 2 dias/2 sessões, sem evidência: continua provisional.
- Os mesmos com 1 cite, ou 1 `get`, ou 1 `useful`: earned, com `earnedBy == "evidence"`.
- Contestação aberta ou flag wrong/outdated impede, como antes. Earned existente não é rebaixado.
- `LifecycleRulesTests`, `LifecyclePassTests` e `LifecycleStoreTests` continuam passando.
## Resultado
(o laço preenche)

- `LifecycleRules.tier`: provisional → earned exige ao menos 1 uso de `usefulUses` também em `evidencedUses`; o `lifecyclePass` grava `earnedBy: "evidence"` nessa promoção. `effective` (texto editado) zera `earnedBy`.
- Earned existentes não são rebaixados (`tier` devolve o tier gravado); ficam com `earnedBy == nil` (= implícito). Quantos não teriam evidência não é mensurável em teste sem ler `lifecycle.json` real: é a contagem de earned com `earnedBy == nil`.
- `promotionCandidate` segue exigindo tier não provisório: a promoção em massa por uso vácuo fica barrada.
