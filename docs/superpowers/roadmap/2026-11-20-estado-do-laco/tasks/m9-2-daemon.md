# M9.2 Daemon: nomes crus no `discard`, histórico com notas, `work stop`, histórico antigo

Leia `onda9.md` e os **achados B3, B4, B5, B6** de `rev-onda78-report.md`. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (~230 `keep`, ~757, ~787-810 `untracked`/`out`/`discard`), `Sources/CollieCore/WorkArchive.swift` (~89 `listed`), `Sources/CollieDaemonKit/WorkLoopCommands.swift` (~50, ~246 `workStop`), `Sources/CollieDaemonKit/ArtifactCommands.swift` (~181 `hidden`, `artifact.folders`).

## Fazer
1. **B3 (perde arquivo do dono):** `untracked` lê o `stdout` cru de `ls-files -z` (`split(separator: "\0")`), sem `out()` e sem `trim`; arquivo do dono chamado `" a.txt"` (espaço no começo) ou `"b.txt "` (no fim) ou com quebra de linha no nome sobrevive ao `discard`. Conferir os demais usos de `out()` que recebem nomes.
2. **B4:** `listed` inclui `|| !notes.isEmpty`; os trabalhos fantasmas de tentativa continuam fora (sem notas).
3. **B5:** `work stop` alcança o laço de um trabalho **fechado** do terminal quando há laço vivo (`workLoops[id]`); a mensagem de recusa do `work run` só promete o que o `stop` faz.
4. **B6:** página `history-*` com `paddockId` nil fica escondida de todo não-admin; `artifact.folders` não devolve os ids `history-*` a quem não os pode ver.

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/DiscardRawNamesTests.swift`
`discard` com `" a.txt"`, `"b.txt "` e nome com `\n` no `keep`: os três **sobrevivem** (mutação: voltar ao `trim` faz falhar); `listed` com só notas = true, sem nada = false; `work stop` para o laço de trabalho fechado; `history-*` sem cercado invisível a terminal e visível ao admin; `artifact.folders` sem esses ids. Fake aplica a regra real; um teste de ponta a ponta em git real para o `discard`.
