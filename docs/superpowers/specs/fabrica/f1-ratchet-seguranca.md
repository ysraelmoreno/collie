# F1: segurança do `factory ratchet` (blockers 1 e 2 e major 2 da rodada 1)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-1.md` (revisor 1: BLOCKER 1, BLOCKER 2, MAJOR 2, MINOR 6). Arquivos: `Sources/CollieDaemonKit/FactoryCommands.swift`, `Sources/CollieCore/FactoryProfile.swift`.

1. **Sandbox do measure.** Com `config.sandboxHome != nil` o `measure` roda sob o perfil e o ambiente de sandbox, como o check do laço (`RouterLoopHost.check`/`profile()`,
   `SandboxLaunch.environment`); sem perfil disponível, recusa (não roda sem sandbox). Com `sandboxHome == nil` (testes, daemon sem sandbox) segue como hoje. Teste SEM
   `sandbox-exec` real (ele não aninha dentro do agente): afirme por um ponto de injeção que `sandboxHome` definido leva `profile != nil` e o HOME do sandbox ao `runCheck`,
   e que sem perfil o comando recusa e não executa nada. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
2. **Baseline em lugar perigoso.** `confinedPath` (parser) e `FactoryRatchet.target` recusam componente `.git` ou terminado em `.git`, `.collie`, e o arquivo `collie-work.json`;
   também componente vazio e `.` (parser e `target` com a mesma regra, uma função só). Testes: cada caso recusado no parser e no comando; `dir/.git`, `x.git/y`, `.collie/b`.
3. **Escrita sem corrida.** `write` abre a pasta do baseline com `open(O_DIRECTORY|O_NOFOLLOW)` componente a componente a partir da raiz do projeto (`openat`), cria o temporário com
   `openat(O_CREAT|O_EXCL|O_NOFOLLOW, 0600)` nesse fd e troca com `renameat` no mesmo fd; a leitura também por `openat` com `O_NOFOLLOW`. Se um componente é link simbólico: recusa.
   Teste: pasta que é symlink para fora é recusada; arquivo temporário não sobra. (A corrida em si não se testa de forma determinística: teste a recusa do link e o uso do fd.)
4. **Medição vazia.** `update` recusa medição vazia (0 chaves) sobre baseline não vazio, com mensagem clara (`check` também avisa). Teste.

Check: `scripts/check-fabrica-loop.sh f1`. Commit ao final, só os arquivos da tarefa.
