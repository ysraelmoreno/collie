# B2.1 Portão do laço (`work run --gate`)

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b2-portao.md` (requisitos 1–6).
Código: `Sources/CollieCore/Work.swift` (`WorkLoopState`), `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`attempt`,
`verdict`, `prompt`), `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`work.run`, `loopCardText`),
`Sources/CollieDaemonKit/Work/WorkStatusText.swift`, CLI em `Sources/collie/`.

## Fazer

1. `WorkLoopState.gate: String?` (decodifica arquivos antigos).
2. `collie work run --gate "<cmd>"`; vazio/só espaço → recusa com mensagem.
3. Em `attempt`: depois do check passar, roda o portão com `host.check`, mesmo timeout e orçamento. Veredito ganha
   `gate failed (exit n)` e `gate timed out`; a cauda da saída do portão vai para a nota como a do check.
4. `loopCardText`: portão uma vez, depois dos limites, em «…»; recusa «» no portão como nas tarefas; conta no limite.
5. `prompt`: depois do check, "e depois este portão:" + o comando.
6. `work status` mostra `portão: <cmd>` num laço com portão.

## Testes (escrever antes)

`WorkLoopTests`: portão falha → tarefa não passa, razão certa; check falha → portão não roda; portão passa → feita.
`WorkLoopCommandTests`: `--gate` vazio recusado; texto do cartão com portão; portão com « recusado.
`WorkStatusTextTests`: linha do portão.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
