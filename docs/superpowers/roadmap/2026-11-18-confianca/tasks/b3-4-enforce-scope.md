# B3.4 `memory enforce`: escopo e caminho

Achados 1 e 5 da revisão da onda 3 (`.collie/briefs/rev-wave3-report.md`, local). Código: `Sources/CollieDaemonKit/MemoryCommands.swift` (`memory.enforce`, por volta das linhas 440-468), `Sources/CollieDaemonKit/Memory/MapDrift.swift` (`safePath`, `existed`).

## Fazer

1. Um **agente** só impõe item de escopo `project` do próprio store (como o `memory.supersede`, que usa só o store do projeto). Itens `global` e de lote: recusa com mensagem em português ("só o dono impõe itens globais ou de lote"). O admin (app) pode, mas só com um `--repo` que dê raiz git (global sem raiz continua recusado).
2. `--by` precisa ser um **arquivo regular rastreado em HEAD**: `MapDrift.safePath(by)` verdadeiro, `existed(at: HEAD, by)` verdadeiro, `lstat` sem symlink e `S_ISREG`. Recusa `.`, `.git`, diretório, symlink, arquivo não rastreado, nome com quebra de linha ou controle. Mensagens em português.
3. `--clear` num item sem `enforcedBy` não grava arquivo nem emite evento (devolve a mensagem "não estava imposto").
4. A mensagem "memory … not found" passa para português como as outras; o `help` de `--by` diz "arquivo rastreado do repositório do item".

## Testes (escrever antes) — `MemoryCommandTests`

`--by .`, `.git`, um diretório, um symlink, um arquivo não rastreado, nome com quebra de linha: todos recusados. Agente impondo item `global` e de lote: recusado. Item de projeto com arquivo rastreado: passa. `--clear` sem imposição: sem evento.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests` (essa suíte sobe terminais e falha com "closed" no sandbox), nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar em scripts/ci/ nem em architecture-rules.txt.
