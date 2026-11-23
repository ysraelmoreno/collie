# F5a: ratchet e doctor (rodada 2, revisor 1 e N3/N4 do revisor 2)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-2.md`. Arquivos: `Sources/CollieDaemonKit/FactoryCommands.swift`, `Sources/CollieCore/FactoryBait.swift`, `FactoryDoctor.swift`, `FactoryProfile.swift`, `Ratchet.swift`, testes.

1. (blocker) A catraca recusa quando a raiz do projeto é o home, um ancestral do home, ou quando o caminho do baseline (resolvido contra a raiz) cai num caminho que o perfil estrito nega (reuse as listas de `EssentialPaths`/`neverWritable`: não copie). Teste: raiz = home com baseline `.zshenv`, `.ssh/authorized_keys`, `Library/LaunchAgents/x` recusados; raiz comum segue funcionando.
2. A ligação do sandbox: teste do roteador (`factoryRatchet`) com `config.sandboxHome` definido e terminal livre: responde `.unavailable` e não roda nada. Sem `sandbox-exec` real.
3. Taxa por persona: numerador só com `r.caught && r.layer == .review` (teste com run de judge com persona).
4. Erro no arquivo de resultados não esconde os escapes válidos das outras camadas (some os escapes dos runs que passam no parse isolado; a camada do run inválido ainda perde 1 por erro).
5. Falha de leitura do baseline (que não seja ausência) propaga o erro; o baseline regravado preserva o modo do arquivo original (0644 quando não existia? use 0644); `fsync` antes do `renameat`; parser e `target` usam a MESMA função de recusa de caminho.
6. Doctor: só as citações do `gate` (não precheck/smoke) tiram o judge de 2; se o runner achado por `testRunnerSource` for `npm|yarn|pnpm (run )?test`, o judge fica em no máximo 2. Ajuste `FactoryModelsTests` sem baixar a nota esperada dos modelos (eles passarão a chamar o runner direto, ver F5b).

Check: `scripts/check-fabrica-loop.sh f5a`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
