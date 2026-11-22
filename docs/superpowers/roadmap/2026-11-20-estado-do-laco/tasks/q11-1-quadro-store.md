# Q11.1 Quadro: armazenamento

Leia `onda11.md` e `q11-contrato.md` (esta pasta). Crie `Examples/apps/quadro/store.py` e `Examples/apps/quadro/tests/test_store.py` (e `tests/__init__.py` se o `unittest discover` precisar).

## Fazer
Classe `Store(dir)` com: `board(include_archived=False)`, `cards(column=None, label=None, assignee=None, q=None)`, `card(id)`, `create_card(title, body="", column="todo", labels=(), assignee="", by="")`, `update_card(id, **campos, by="")`, `move_card(id, column, index=None, by="")`, `comment(id, text, by="")`, `archive(id, by="")`, `restore(id, by="")`, `events(since=0, limit=200)`, `revision`. Erros tipados: `NotFound`, `Invalid` (mensagem curta, vira `404`/`400` no servidor), `StoreCorrupt`. Tudo conforme o contrato: arquivos `board.json`, `BOARD.md`, `events.jsonl` (+ giro de 5 MB), escrita atômica, trava de processo e de thread, permissões `0700`/`0600`, limites, `revision` e `seq`.
- Uma mudança = **uma** gravação do `board.json`, depois o evento, depois o espelho. Se a gravação do diário ou do espelho falhar, a mudança já feita vale e a operação não falha.
- Dois `Store` na mesma pasta (dois processos) não perdem mudança uma da outra: leia o arquivo sob a trava a cada operação (não confie em cache de memória).
- `q` procura (sem diferenciar maiúscula) no título, corpo, rótulos e comentários.

## Testes (`unittest`, pasta temporária, sem `sleep`)
Criar/ler/atualizar/mover (ordem por `index`, para o fim, para outra coluna)/comentar/arquivar/restaurar; limites e coluna desconhecida = `Invalid`; `NotFound`; `revision` e `seq` sobem 1 a 1 e batem com o diário; **persistência:** reabrir o `Store` na mesma pasta devolve o mesmo quadro; **atomicidade:** simular falha entre o arquivo temporário e o `replace` (monkeypatch de `os.replace`) deixa o `board.json` antigo intacto; `board.json` corrompido = `StoreCorrupt` e o arquivo **não** é tocado; dois `Store` alternando gravações não perdem nada; `BOARD.md` escapa `#`, `[`, `<`, crases e quebras de linha de título, corpo, comentário e `by` (um título `# x\n- [a](http://b)` não vira cabeçalho nem link); giro do diário com o limite reduzido por parâmetro; permissões `0600`/`0700`; `by` com caractere de controle é limpo.

## Check
`cd Examples/apps/quadro && python3 -m unittest tests.test_store -v` (Python 3.9, só biblioteca padrão).
