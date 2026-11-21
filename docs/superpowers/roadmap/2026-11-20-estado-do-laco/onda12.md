# Estado do laço, Onda 12: Quadro com tipos de tarefa e prioridade

Pedido do dono (2026-11-21), depois do design aprovado (`docs/pages/quadro-design/index.html`): cartões com **tipo** (impl, bug, refactor, spike, test, docs, chore), **prioridade**, e os cartões que já existem viram `impl`. Contrato base: `q11-contrato.md` (esta pasta); esta onda só o estende. Código: `Examples/apps/quadro/` (Python 3.9 stdlib; UI sem `innerHTML`; público: nada de nome interno nem caminho pessoal).

| # | Tarefa | Escopo | Depende de |
|---|---|---|---|
| Q12.1 | Tipo e prioridade no armazenamento e na API, com migração dos cartões existentes | `store.py`, `server.py`, `tests/test_store.py`, `tests/test_server.py` | |
| Q12.2 | Os 10 comandos dos agentes aceitam e filtram por tipo e prioridade | `collie.json`, `README.md`, `tests/test_contract.py`, `docs/feature-map.md` | Q12.1 |
| Q12.3 | UI: chips de tipo, filtros, marcador de prioridade, seletores no detalhe (conforme o protótipo) | `ui/**`, `tests/test_ui.py` | |

Check de cada tarefa: `scripts/check-onda12.sh <q12-1..q12-3>`. Depois do laço, o Pastor reinicia o serviço do app (o servidor em execução não recarrega o código) e confere o quadro vivo.

## Contrato novo (vale para as três tarefas)
- `type`: um de `impl`, `bug`, `refactor`, `spike`, `test`, `docs`, `chore`. Padrão ao criar: `impl`.
- `priority`: um de `high`, `medium`, `low`. Padrão ao criar: `medium`. (Rótulos na UI: Alta, Média, Baixa.)
- Valor fora da lista = `400 {"error": "tipo inválido"}` / `"prioridade inválida"` (nunca aceitar e gravar).
- `POST /api/card/create` e `/api/card/update` aceitam `type` e `priority` (update: só muda o que vier). `GET /api/cards` ganha os filtros `?type=` e `?priority=` (combinam com os de hoje). `GET /api/board` e `/api/card` devolvem os dois campos em **todo** cartão.
- **Migração:** `schema` 1 → 2. Ao abrir um `board.json` de `schema` 1, o `Store` grava antes uma cópia `board.json.v1.bak` (0600, só se ainda não existir), põe `type: "impl"` e `priority: "medium"` em **todos** os cartões (arquivados também), sobe o `schema` para 2, grava de forma atômica, registra um evento `migrate` no diário e regera o `BOARD.md`. É idempotente (abrir de novo não faz nada) e nunca sobrescreve um arquivo que não decodifica. Um cartão de `schema` 2 sem `type`/`priority` (editado à mão) lê como `impl`/`medium` e é corrigido na próxima gravação.
- O espelho `BOARD.md` e o diário mostram tipo e prioridade (escapados como o resto).
- Mudar tipo ou prioridade gera evento no diário (`type`, `priority`, com `by`), como as outras mudanças; mudar para o mesmo valor não gera evento.
