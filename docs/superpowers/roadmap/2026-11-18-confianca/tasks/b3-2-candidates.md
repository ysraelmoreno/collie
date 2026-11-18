# B3.2 Candidatas a regra

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b3-armadilha-regra.md` (requisito 4). Depende de B3.1.

## Fazer

1. Constante nomeada `enforceCandidateHits = 3`. Candidata: `pitfall`, `active`, sem `enforcedBy`, `hits ≥` constante.
2. `collie memory list --candidates` (e o parâmetro equivalente na ferramenta MCP de listagem), ordenado por `hits`.
3. `memory stats`: seção com o número de candidatas e as 5 primeiras.
4. Orientação do Pastor: uma linha só quando há candidatas: `N armadilhas recorrentes podem virar checagem: collie memory
   list --candidates`. Respeitar o teto de tamanho da orientação.

## Testes (escrever antes)

`MemoryCommandTests` (filtro), `MemoryObservabilityTests` (seção do stats), `CollieOrientationTests` (linha aparece
com candidatas, some sem).

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
