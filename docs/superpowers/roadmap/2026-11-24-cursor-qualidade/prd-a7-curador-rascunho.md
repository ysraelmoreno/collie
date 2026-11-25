# PRD A7: curador não promove rascunho de lote para o projeto

PRD geral: `README.md` desta pasta (problema 1, parte da memória).

## Problema

Na rodada 2 (lote `cursor-test`, arquivos só em `.collie/cursor-test/`), o curador (haiku) criou a armadilha
`A7884AFE` "Slug por regex ASCII apaga letras não decompostas por NFD" com `scope: project` e `status: active`,
`origin: curador`. O assunto era um arquivo descartável fora do repositório rastreado. Agentes de outros lotes passam a
recebê-la. Descartar é `memory review … discard`, só admin.

A escolha do escopo hoje é do modelo: o prompt diz "num lote, use lot no lugar de project"
(`MemoryLearning.swift`, ~linha 36), e o código só corrige escopo `global` que vaza o lote (~linha 377).

## Fazer (`Sources/CollieDaemonKit/Memory/MemoryLearning.swift`, `Tests/CollieDaemonKitTests/CuratorScopeTests.swift`)

1. Regra no código, não no prompt: quando o contexto do job tem lote (`ctx.lot`), um registro do curador com escopo
   `project` é gravado como `lot` daquele lote. O dono promove com `memory promote` se quiser.
   Verificar antes se o job da captura do Cursor (`ConversationCapture`/`CursorCuratorRunner`) leva o lote do terminal;
   se não levar, passar a levar (no caso de 2026-11-24 a origem ficou só `curador`, sem nome de terminal).
2. Quando todos os caminhos citados no registro (`path` e caminhos no corpo, pelo mesmo critério que o código já usa
   para achar caminhos, se houver; senão só `path`) estão sob `.collie/` da worktree, o registro entra como `proposed`,
   não `active`.
3. Uma linha no diário do curador (`entry(...)`) quando 1 ou 2 mudam o que o modelo pediu.

## Aceite

- Job com lote, modelo pede `project`: gravado `lot` (suíte nova `CuratorScopeTests`, no molde de `CorrectionTests`/`ProcedureTests`, que já exercitam a gravação do curador).
- Job sem lote: `project` como hoje (teste).
- Registro só sobre `.collie/cursor-test/slug.py`: `proposed` (teste).

## Check

```
swift test --disable-sandbox --filter CuratorScopeTests && swift test --disable-sandbox --filter CorrectionTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
