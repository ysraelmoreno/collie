# M11.2 CI: cache de `.build`, timeout por shard e log da última suíte iniciada

Leia `onda11.md` e P2, P3, P4 de `aval-suite-report.md`. Medida: build a frio 6 a 9 min a cada run; Testes (3 shards seriais, `--no-parallel`) levam 30 a 52+ min, com um run cancelado aos 52 min e 2 processos `swiftpm-testing` mais um `adb` ainda vivos. Código: `.github/workflows/ci.yml`, `scripts/ci/run-tests.sh` (+ `scripts/ci/ci-skip.txt` e vizinhos).

## Fazer
1. **Cache de `.build`** em `ci.yml` com `actions/cache` (versão fixa por SHA ou tag exata já usada no repositório; veja os outros usos em `.github/workflows/`): chave com `runner.os`, a versão do Swift e `hashFiles('Package.resolved', 'Package.swift')`; `restore-keys` pelo prefixo. Só o `.build` do build de teste do CI; **o workflow de release (`release.yml`) não muda** (build a frio e assinado).
2. **Timeout por shard** em `run-tests.sh`: cada shard roda sob `timeout` (padrão 900 s, ajustável por `CI_SHARD_TIMEOUT`; no macOS do runner use o que existir: `gtimeout`, `timeout` ou um watchdog em bash puro, sem instalar nada). Estouro = o shard **falha** e imprime as últimas 40 linhas do log dele e **o nome da última suíte/teste iniciado** (`grep` das linhas `◇ Test ... started`/`Test Case ... started` no log), em vez de ficar mudo até o cancelamento.
3. **Log por shard visível:** cada shard grava o log em arquivo e imprime um resumo `shard i ok|FALHOU: N testes, Xs`; ao falhar, o rabo do log. Mantenha a checagem por contagem final que já existe (o `swift test` puro dava verde com falhas: nunca volte a confiar só no exit code).
4. Mate processos órfãos no fim de cada shard (`swiftpm-testing`, `adb` iniciados pelo shard) para a trava de um shard não segurar o job.
5. **Não** troque `--no-parallel` por paralelo nesta tarefa (só depois de achar a trava): deixe um comentário `# ponytail:` com o próximo passo.

## Testes
`scripts/ci/test-run-tests.sh` (novo, bash puro, sem Swift): cria um "swift" falso no `PATH` temporário que (a) passa, (b) trava para sempre e (c) falha com texto, e confirma: passa → exit 0 e resumo; trava → o shard falha em ≤ 5 s com `CI_SHARD_TIMEOUT=2` e o log diz a última suíte iniciada; falha → exit ≠ 0 com o rabo do log; contagem a menos → falha. O fake aplica a regra real (nada de "aceita tudo").

## Check
`bash -n scripts/ci/run-tests.sh && scripts/ci/test-run-tests.sh && scripts/ci/lint.sh && scripts/ci/check-architecture.sh`. Valide o YAML do workflow com `python3 -c "import yaml…"` se `yaml` existir; senão com `ruby -ryaml -e` ou revisão manual descrita no commit.
