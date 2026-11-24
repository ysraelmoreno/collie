# R3: `WorkStore.enforce` não cria um formatter por chamada

Origem: auditoria de simplicidade de 2026-11-23. `Sources/CollieDaemonKit/Work/WorkStore.swift` (~233), em `enforce`, faz `let iso = ISO8601DateFormatter()` em TODA chamada (roda em todo `mutate`), mas o formatter só é usado dentro de `tag(...)`, quando algo é expulso.

Fazer: tire a criação do caminho comum. Dois caminhos aceitos: um `static let` (formatter só leitura, como os outros do código) ou criar dentro de `tag`. Comportamento e conteúdo do diário idênticos. NÃO mude o formato do `work.json`, nem o limite de trabalhos fechados, nem o resto de `mutate`.

Check: `scripts/check-refactor-loop.sh r3`. Commit ao final, só os arquivos da tarefa. Se usar `static let` com `nonisolated(unsafe)`, o lint conta isso: prefira criar dentro de `tag`, ou um `static let` que o compilador aceite sem `unsafe`.
