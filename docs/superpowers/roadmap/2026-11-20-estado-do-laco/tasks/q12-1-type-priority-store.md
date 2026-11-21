# Q12.1 Tipo e prioridade no armazenamento e na API, com migração

Leia `onda12.md` (o contrato novo e a migração) e `q11-contrato.md`. Código: `Examples/apps/quadro/store.py`, `server.py` e os testes.

## Fazer
1. `store.py`: constantes `TYPES` e `PRIORITIES`; `create_card(..., type="impl", priority="medium")`, `update_card(..., type=None, priority=None)`; `cards(..., type=None, priority=None)` filtra; erros `Invalid("tipo inválido")` / `Invalid("prioridade inválida")`; os cartões devolvem os dois campos sempre. `schema` passa a 2.
2. **Migração do `schema` 1** exatamente como em `onda12.md`: cópia `board.json.v1.bak` (0600, só se não existir), `type: impl` e `priority: medium` em todos os cartões (arquivados também), `schema: 2`, gravação atômica, evento `migrate` no diário, espelho regerado, idempotente. `board.json` que não decodifica continua `StoreCorrupt` sem tocar no arquivo; um `schema` maior que 2 também é recusado sem tocar.
3. `server.py`: `create`/`update` aceitam `type` e `priority` (valor inválido = 400); `GET /api/cards` aceita `?type=` e `?priority=`; o SSE e o `/api/board` já saem com os campos porque vêm do `Store`.
4. `BOARD.md` e diário trazem os dois campos (escapados); mudança de tipo/prioridade gera evento, o mesmo valor não.

## Testes (`unittest`, pasta temporária, sem `sleep`)
Criar com e sem tipo/prioridade (padrões `impl`/`medium`); valores inválidos = `Invalid`/400; atualizar só um dos campos; filtros por tipo, por prioridade e combinados; **migração:** um `board.json` de `schema` 1 escrito à mão com 3 cartões (um arquivado) abre com todos `impl`/`medium`, `schema` 2, `.v1.bak` idêntico ao original, evento `migrate`, abrir de novo não muda nada (revisão e arquivo iguais); migração com `board.json.v1.bak` já existente não sobrescreve a cópia; `schema` 3 e JSON quebrado = `StoreCorrupt` sem alterar o arquivo; cartão de `schema` 2 sem os campos lê como `impl`/`medium`; espelho e diário escapam; o servidor responde os campos em `board`, `card`, `cards`, e no SSE.

## Check
`scripts/check-onda12.sh q12-1`.
