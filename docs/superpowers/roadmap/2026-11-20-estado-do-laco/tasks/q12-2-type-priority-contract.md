# Q12.2 Os comandos dos agentes aceitam e filtram por tipo e prioridade

Leia `onda12.md` e `q11-contrato.md`. O servidor (Q12.1) já está commitado. Código: `Examples/apps/quadro/collie.json`, `README.md`, `tests/test_contract.py`, `docs/feature-map.md`.

## Fazer
1. `collie.json`: `create-card` e `update-card` ganham os parâmetros `type` (uma de: impl, bug, refactor, spike, test, docs, chore; padrão impl ao criar) e `priority` (high, medium ou low; padrão medium ao criar); `list-cards` ganha os filtros `type` e `priority`. Os `help` dizem os valores aceitos, em português. Os outros comandos não mudam. Nada destrutivo.
2. `README.md` (inglês): os 7 tipos e as 3 prioridades em uma tabela curta, os parâmetros novos, e a migração do `schema` 1 → 2 (a cópia `board.json.v1.bak`).
3. `docs/feature-map.md`: ajuste a linha do Quadro (tipo e prioridade).

## Testes
`tests/test_contract.py`: os parâmetros novos existem com os valores certos; um comando de cada tipo e prioridade, chamado com o servidor real em porta `0`, devolve o cartão com os campos e sem `404`/`405`/`400`; valor inválido devolve `400`; os nomes dos comandos continuam os 10 de antes; o README não tem caminho pessoal nem nome interno.

## Check
`scripts/check-onda12.sh q12-2`.
