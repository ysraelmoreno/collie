# Q11.2 Quadro: servidor HTTP loopback e SSE

Leia `onda11.md`, `q11-contrato.md` e a `store.py` da Q11.1 (já commitada). Crie `Examples/apps/quadro/server.py` e `Examples/apps/quadro/tests/test_server.py`.

## Fazer
`server.py`: `http.server.ThreadingHTTPServer` ligado só a `127.0.0.1` (`--port N`, `0` = efêmera, e o servidor imprime a porta real numa linha `quadro: http://127.0.0.1:<porta>`; `--dir` ou `QUADRO_DIR`), `serve(store, port=0, ping=15.0)` importável para os testes. Implemente **todas** as rotas e regras de segurança do contrato: `Host`/`Origin` loopback, `Content-Type` e limite de 64 KB, erros `{"error": …}` sem rastro de pilha nem caminho, nada de CORS, arquivos estáticos de `ui/` só pela lista fixa (`index.html`, `app.js`, `style.css`) sem `..`.
- SSE: cada cliente recebe o documento ao conectar e a cada mudança (`event: document`, um JSON por `data:`), `: ping` no intervalo configurado; cliente que cai é removido sem derrubar o servidor; sem fila sem limite (cliente lento perde os intermediários e recebe o último estado, nunca bloqueia as escritas).
- Os erros do `Store` viram o status certo (`Invalid`→400, `NotFound`→404, `StoreCorrupt`→500 com mensagem fixa).
- Desligamento limpo (`shutdown` fecha as conexões SSE) para o teste não pendurar.

## Testes (`unittest`; servidor em thread, porta `0`, `http.client`/`urllib`; sem `sleep`: sincronize por eventos/`threading.Event`)
Cada rota (feliz e erro); criar→mover→comentar→arquivar→restaurar de ponta a ponta e persistência em disco depois de recriar o servidor sobre a mesma pasta; `Host: evil.example` = 403/400; `Origin: http://evil.example` = recusado; `POST` com `text/plain` = 415; corpo de 65 KB = 413; JSON inválido = 400; método errado = 405; `/ui/../store.py` e `/ui/%2e%2e/store.py` = 404; SSE: o cliente recebe o documento inicial, e depois um `create` num segundo cliente chega ao primeiro (com `events` contendo o evento novo); o `: ping` chega com `ping=0.05`; mutações concorrentes (8 threads criando cartões) = nenhuma perdida e `revision` consistente; resposta de erro não contém o caminho da pasta de dados.

## Check
`cd Examples/apps/quadro && python3 -m unittest tests.test_store tests.test_server -v`.
