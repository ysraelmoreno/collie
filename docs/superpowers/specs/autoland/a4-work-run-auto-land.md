# A4: `work run --auto-land`

Roadmap: `docs/superpowers/roadmap/2026-11-24-autoland/README.md`. Só vale num cercado marcado como fábrica (A2) e só o dono liga. Fail closed: qualquer dúvida PARA o laço com `stopReason` próprio e chama o dono. **Nunca faz push, nunca abre PR; só `merge` local.**

## Comportamento
Nova flag `--auto-land` em `work run` (CLI; no MCP também só via cartão do dono, como o resto dos limites). Recusada com mensagem clara se: o cercado não é fábrica; o perfil não tem `gate`; `--no-review` está ligado ou a revisão do perfil está desligada (auto-land exige revisão).
Quando TODAS as tarefas do trabalho terminam `done`, antes de encerrar o laço o motor verifica, nesta ordem, parando na primeira que falhar:
1. portão (`gate` do perfil COMMITADO no base) verde sobre o HEAD do cercado;
2. a última tentativa de cada tarefa teve revisão ligada e SEM veto (parecer mudo/inválido não conta como aprovação: para);
3. CI local: `scripts/ci/run-tests.sh` (ou o comando em `factory.autoland.ci` do perfil, se existir) verde, com timeout do perfil (padrão 1800 s);
4. árvore do cercado limpa e nenhum outro agente do cercado ocupado;
5. a base não andou de um modo que torne o merge não-trivial: `paddock land` em modo `merge` aplicado pelo caminho já existente (`PaddockManager.land`); conflito ou falha ⇒ para sem desfazer nada que o land normal já desfaz.
Se tudo passa: `paddock land` (merge), registra no diário e na nota o commit anterior da base (para reverter com `git reset`/revert) e o novo; `stopReason` = `landed`. Cada falha tem `stopReason` próprio: `landGateRed`, `landReviewVeto`, `landCiRed`, `landDirty`, `landConflict`, `landNotFactory`. Todos chamam o dono por `notify` com uma linha explicando e o comando para ver o resto.

## Fora do escopo
Próximo trabalho da fila (A5), resumo imutável (A6), aceite em runtime (F3). Não mude o isolamento do juiz nem `--review`.

## Testes (`Tests/CollieDaemonKitTests`, hosts falsos; sem terminais reais, sem `sandbox-exec`, sem git de rede)
Recusas (não fábrica, sem gate, sem revisão); cada condição falhando dá o `stopReason` certo e NÃO chama land; sucesso chama land uma vez em modo merge e grava os dois commits; parecer mudo bloqueia; nunca chama push/PR (teste que o host de land falso só aceita `merge`).

Check: `scripts/check-autoland-loop.sh a4`. Commit ao final, só os arquivos da tarefa.

Nome obrigatório da suíte (o check filtra por ela): `AutoLandTests` (arquivo novo em `Tests/CollieDaemonKitTests`).
