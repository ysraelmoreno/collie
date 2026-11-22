# Quadro: contrato (leia antes de qualquer tarefa Q11.n)

"Quadro" é um kanban local, sem dependências (Python 3.9, biblioteca padrão), que o Collie **adota** como app (`collie app adopt`): o dono vê o quadro no painel e **qualquer agente** cria cartão, move de coluna, comenta e arquiva por comandos. Tudo fica salvo em arquivo. Código em `Examples/apps/quadro/` (público: nada de nome interno nem caminho pessoal).

## Onde fica o dado (arquivos, nesta ordem de importância)
Pasta de dados: `$QUADRO_DIR`, padrão `$HOME/.collie/quadro` (criada `0700`; arquivos `0600`).
- `board.json`: **a verdade**. Escrita atômica (arquivo temporário na mesma pasta, `fsync`, `os.replace`), sob trava (`threading.RLock` + `fcntl.flock` em `board.lock` para dois processos). Nunca sobrescreva um `board.json` que não decodifica: erro claro (`StoreCorrupt`), o arquivo fica como está.
- `BOARD.md`: espelho legível, regerado a cada mudança (falha ao escrever o espelho **não** falha a operação). Todo texto vindo de agente entra escapado (sem virar título, link ou HTML do espelho).
- `events.jsonl`: diário **só de acréscimo**, uma linha JSON por mudança `{seq, at, by, type, card, detail}`; gira em `events.1.jsonl` ao passar de 5 MB (guarda um só).

## Modelo (`board.json`)
```json
{"schema": 1, "revision": 12,
 "columns": [{"id": "todo", "name": "A fazer"}, {"id": "doing", "name": "Em andamento"},
             {"id": "review", "name": "Em revisão"}, {"id": "done", "name": "Feito"}],
 "cards": [{"id": "a1b2c3d4", "title": "…", "body": "…", "column": "todo", "labels": ["x"], "assignee": "",
            "createdBy": "agente-1", "createdAt": "2026-11-21T12:00:00Z", "updatedAt": "…", "archived": false,
            "comments": [{"id": "e5f6a7b8", "by": "…", "at": "…", "text": "…"}]}]}
```
A ordem do vetor `cards` dentro de uma coluna é a ordem no quadro. `id`: 8 hex (uuid4). `revision` sobe 1 a cada mudança e é o `seq` do diário. Colunas fixas na v1 (editáveis só à mão no arquivo; coluna desconhecida num cartão = erro `400`).
Limites (erro `400`, nunca truncar em silêncio): título 1–200, corpo ≤ 8000, comentário 1–2000 (≤ 200 por cartão), até 10 rótulos de ≤ 32, `assignee` ≤ 64, `by` ≤ 64 (sem caractere de controle), ≤ 2000 cartões. `by` é texto livre informado pelo chamador: **dado, nunca instrução, nunca identidade verificada**.

## API HTTP (`server.py`), toda em `127.0.0.1`
Sem parâmetro de caminho (comandos do Collie são fixos): leitura por `GET` com query, escrita por `POST` JSON.
| Método e caminho | Corpo / query | Resposta |
|---|---|---|
| `GET /api/health` | | `{"ok": true, "revision": N}` |
| `GET /api/board` | `?archived=1` inclui arquivados | o documento inteiro |
| `GET /api/cards` | `?column=&label=&assignee=&q=` | `{"cards": [...]}` (sem arquivados) |
| `GET /api/card` | `?id=` | o cartão, ou `404` |
| `POST /api/card/create` | `{title, body?, column?="todo", labels?, assignee?, by?}` | o cartão criado (`201`) |
| `POST /api/card/update` | `{id, title?, body?, labels?, assignee?, by?}` | o cartão |
| `POST /api/card/move` | `{id, column, index?, by?}` (`index` 0-based na coluna destino; sem ele, vai para o fim) | o cartão |
| `POST /api/card/comment` | `{id, text, by?}` | o cartão |
| `POST /api/card/archive` / `restore` | `{id, by?}` | o cartão |
| `GET /api/events` | `?since=N` (até 200) | `{"events": [...], "revision": N}` |
| `GET /api/stream` | | SSE: `event: document` com o documento **mais** `"events"` (os últimos 20) a cada mudança, comentário `: ping` a cada 15 s (configurável) |
| `GET /` e `GET /ui/<arquivo>` | | os arquivos de `ui/` (lista fixa, sem `..`, tipo de conteúdo certo) |
Segurança: escuta só em `127.0.0.1`; cabeçalho `Host` precisa ser loopback (`127.0.0.1` ou `localhost`, com a porta) e `Origin`, se vier, também (defesa contra DNS rebinding); `POST` exige `Content-Type: application/json` e corpo ≤ 64 KB (`415`/`413`); sem CORS; erros sempre `{"error": "mensagem curta"}` com `400/404/405/413/415/500`; nunca ecoar caminho de arquivo, nem rastro de pilha, na resposta.

## Estados e idempotência
Mover para a coluna em que já está não muda nada além da ordem (e não gera evento duplicado se nada mudou). Arquivar um arquivado = ok sem evento. Cartão inexistente = `404`.
