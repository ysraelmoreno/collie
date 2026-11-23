# F7a: o CLI confina o que grava (rodada 4, revisor 1)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-4.md` (revisor 1). Arquivos: `Sources/collie/CLI.swift`, `Sources/CollieCore/Ratchet.swift`, `Sources/CollieDaemonKit/FactoryCommands.swift`, `Sources/CollieCore/FactoryDoctor.swift`, `docs/superpowers/specs/fabrica/f6a-ratchet-cli-grava.md`, testes.

1. (major) O daemon devolve `root` e `rel` no lugar de `path`. O CLI NÃO confia neles: reaplica `FactoryProfile.confinedPath(rel)`; exige que `root` seja a raiz de projeto calculada pelo PRÓPRIO processo a partir do seu cwd (a mesma regra de `ProjectRoot`);
   abre a pasta por `openat(O_DIRECTORY|O_NOFOLLOW)` componente a componente a partir da raiz (a raiz também com `O_NOFOLLOW`): mova `FactoryRatchet.openDir` para `Sources/CollieCore` e reuse nos dois lados (leitura do daemon, escrita do CLI). Com `--terminal` de outro terminal
   (o CLI não roda dentro do sandbox daquele terminal), `update` e `raise` ficam recusados com mensagem clara (`check` segue valendo, só lê).
2. Testes: pasta do meio como symlink no escritor dá erro e deixa o alvo intocado; `rel` com `..`, absoluto, `.git`, `.collie` recusado no CLI mesmo que o daemon o devolva; `root` diferente da raiz do cwd recusado; extrair a função pura `handleRatchet(result) -> (JSONValue, Int32)` do trecho
   de `CLI.swift` e testar: `newBaseline` não nulo grava e põe `wrote: true`; erro do escritor sai 1 sem imprimir; `check` não grava; `--terminal` alheio recusa `update`/`raise`.
3. Menores: `viaPackageScript` casa `bun` só com `bun run test`/`bun run t` (`bun test` é runner nativo e não conta), `npm -s test`/`npm --silent test` casam (flag no meio), `npm run t`/`yarn t` NÃO casam como `test`; ajuste `everyPackageManagerSpelling`. O CLI limita `newBaseline` a 2 MiB e as linhas `#` do baseline antigo
   passam pelo filtro de controle (descartar a linha). O daemon abre a raiz UMA vez e usa o mesmo fd em `place` e `openDir` (nit 6). Atualize a spec F6a §2 (sem "instrução para o MCP").

Check: `scripts/check-fabrica-loop.sh f7a`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
