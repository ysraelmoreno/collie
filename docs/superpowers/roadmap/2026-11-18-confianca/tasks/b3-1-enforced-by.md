# B3.1 Armadilha imposta por checagem (`enforcedBy`)

PRD: `docs/superpowers/roadmap/2026-11-18-confianca/prd-b3-armadilha-regra.md` (requisitos 1–3 e 6).
Código: `Sources/CollieCore/Memory*.swift` (`MemoryRecord`, inclusive o formato texto com `kv[…]`),
`Sources/CollieDaemonKit/Memory/MemoryService.swift`, injeção (hook de memória relacionada, checklist), CLI e MCP em
`Sources/collie/`.

## Fazer

1. `MemoryRecord.enforcedBy: String?` no Codable e no formato texto.
2. `collie memory enforce <id> --by <caminho>` / `--clear`, e a ferramenta MCP `memory_enforce` (`id`, `by`, `clear`).
   Só `pitfall` e decisão; caminho relativo, sem `..`, existente na worktree de quem chama. Evento no log de memória.
3. Itens com `enforcedBy`: fora do hook de memória relacionada e do checklist; `memory get` e `search` mostram
   `imposta por <caminho>`.

## Testes (escrever antes)

`MemoryRecordTests` (ida e volta Codable e texto), `MemoryCommandTests` (enforce/clear, recusas: tipo errado, caminho
inexistente, `..`), `LifecycleInjectionTests` ou `MemoryHookTests` (item imposto não é injetado), `ChecklistTests`.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Textos que o dono vê em português. Um commit (ou mais) com mensagem convencional; nada de push.
