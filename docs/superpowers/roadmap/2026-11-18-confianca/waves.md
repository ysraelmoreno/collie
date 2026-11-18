# Ondas: tarefas e checks prontos para o laço

Rodar da raiz da worktree do cercado. `T=docs/superpowers/roadmap/2026-11-18-confianca/tasks`.
O caminho normal é o Pastor montar isto via `/collie:loop` e o dono aprovar no cartão; os comandos abaixo são o que ele
deve chegar a chamar. Cada onda num `collie work start` próprio (um trabalho por onda), depois do land da anterior.

## Preparação (uma vez por cercado)

```sh
git status --short --untracked-files=no   # precisa sair vazio
swift build --build-tests                 # aquece o .build: o 1º check a frio pode passar dos 1800 s
```

## Onda 1: Fundação

```sh
T=docs/superpowers/roadmap/2026-11-18-confianca/tasks
collie work task add "A2.1 lint em catraca" --spec $T/a2-1-lint.md \
  --check "bash scripts/ci/lint.sh && bash scripts/ci/test-lint.sh && grep -q 'sleep Sources/CollieDaemonKit/AskCoordinator.swift 15' scripts/ci/lint-baseline.txt"
collie work task add "A3.1 fronteiras de módulo" --spec $T/a3-1-architecture.md \
  --check "bash scripts/ci/check-architecture.sh && bash scripts/ci/test-check-architecture.sh && grep -q 'forbid-closure collie SwiftTerm' scripts/ci/architecture-rules.txt"
collie work task add "A1.2 workflow de CI" --spec $T/a1-2-ci-workflow.md \
  --check "ruby -ryaml -e 'w=YAML.load_file(%q(.github/workflows/ci.yml)); o=w[%q(on)]||w[true]; exit(o.key?(%q(pull_request)) ? 0 : 1)' && grep -q check-architecture.sh .github/workflows/ci.yml && ! grep -qF secrets. .github/workflows/ci.yml"
collie work run --max 12 --tries 3 --timeout 3600 --budget 21600
```

Medida depois do land: abrir um PR de teste e ver o CI (PRD A1, "Medida de resultado").

## Onda 2: Portão e evidência

```sh
T=docs/superpowers/roadmap/2026-11-18-confianca/tasks
G='bash scripts/ci/lint.sh && bash scripts/ci/check-architecture.sh'
collie work task add "B2.1 portão do laço" --spec $T/b2-1-gate.md \
  --check "swift test --disable-sandbox --filter 'WorkLoopTests|WorkLoopCommandTests|WorkStatusTextTests' && $G"
collie work task add "B1.1 gravar evidência" --spec $T/b1-1-evidence-record.md \
  --check "swift test --disable-sandbox --filter 'WorkLoopTests|WorkStoreTests' && $G"
collie work task add "B1.2 mostrar evidência" --spec $T/b1-2-evidence-show.md \
  --check "swift test --disable-sandbox --filter 'WorkStatusTextTests|WorkPanelTests|WorkLoopCommandTests' && $G"
collie work task add "B2.2 ensinar o portão" --spec $T/b2-2-gate-docs.md \
  --check "grep -q -- --gate docs/referencia.md && grep -q -- --gate Sources/CollieDaemonKit/Work/LoopCommand.swift && swift test --disable-sandbox --filter LoopCommandTests"
collie work run --max 12 --tries 3 --timeout 3600 --budget 28800
```

**Entre a onda 2 e a 3:** `--gate` e a evidência só existem no Collie instalado depois de um release (ou de instalar o
build do branch). Sem isso, nas ondas 3–4 tire o `--gate` e acrescente `&& $G` ao fim de cada check.

## Onda 3: Memória que vira regra

Só depois da medição da memória (memória `memory-improvements-status`): B3.1 não muda a injeção até alguém rodar
`memory enforce`, mas melhor não arriscar o baseline.

```sh
T=docs/superpowers/roadmap/2026-11-18-confianca/tasks
collie work task add "B3.1 enforcedBy" --spec $T/b3-1-enforced-by.md \
  --check "swift test --disable-sandbox --filter 'MemoryRecordTests|MemoryCommandTests|LifecycleInjectionTests|MemoryHookTests|ChecklistTests'"
collie work task add "B3.2 candidatas" --spec $T/b3-2-candidates.md \
  --check "swift test --disable-sandbox --filter 'MemoryCommandTests|MemoryObservabilityTests|CollieOrientationTests'"
collie work task add "B3.3 checagem sumiu" --spec $T/b3-3-enforced-drift.md \
  --check "swift test --disable-sandbox --filter 'MapDriftPassTests|MapDriftTests'"
collie work run --max 9 --tries 3 --timeout 3600 --budget 21600 \
  --gate 'bash scripts/ci/lint.sh && bash scripts/ci/check-architecture.sh'
```

Depois: **A4 manual** (PRD B3, requisito 7): `collie memory list --candidates`, decidir com o dono, converter ≥ 3.

## Onda 4: Vocabulário e métrica

```sh
T=docs/superpowers/roadmap/2026-11-18-confianca/tasks
collie work task add "B4.1 mapa de funcionalidades" --spec $T/b4-1-feature-map.md \
  --check 'for f in Sources/ColliePlugins/*Panel.swift; do grep -q "$(basename "$f" .swift)" docs/feature-map.md || exit 1; done; grep -q feature-map scripts/ci/lint.sh && bash scripts/ci/test-lint.sh'
collie work task add "B4.2 laço aponta o mapa" --spec $T/b4-2-feature-map-prompt.md \
  --check "swift test --disable-sandbox --filter WorkLoopTests && grep -q feature-map docs/referencia.md"
collie work task add "B5.1 números do laço" --spec $T/b5-1-loop-stats.md \
  --check "swift test --disable-sandbox --filter 'WorkSummaryTests|WorkStatusTextTests'"
collie work task add "B5.2 revertidos" --spec $T/b5-2-reverts.md \
  --check "swift test --disable-sandbox --filter WorkSummaryTests"
collie work run --max 12 --tries 3 --timeout 3600 --budget 28800 \
  --gate 'bash scripts/ci/lint.sh && bash scripts/ci/check-architecture.sh'
```

## Onda 5: Queima (opcional, decidir com os números de B5)

```sh
T=docs/superpowers/roadmap/2026-11-18-confianca/tasks
collie work task add "B1.3 arquivos de evidência" --spec $T/b1-3-evidence-files.md \
  --check "swift test --disable-sandbox --filter 'WorkLoopTests|WorkLoopCommandTests|WorkPanelTests|WorkLoopSandboxTests'"
collie work task add "A2.2 zerar try! e as!" --spec $T/a2-2-force-zero.md \
  --check "! grep -rnE 'try!|as! ' Sources && ! grep -q '^force ' scripts/ci/lint-baseline.txt && swift test --disable-sandbox --filter 'ClaimChecksTests|MapDriftPassTests'"
collie work task add "A2.3 auditoria sleep e concorrência" --spec $T/a2-3-audit.md \
  --check 'A=docs/superpowers/roadmap/2026-11-18-confianca/audit-sleep-concurrency.md; for f in $(grep -E "^(sleep|unsafe-concurrency) " scripts/ci/lint-baseline.txt | cut -d" " -f2); do grep -qF "$f" "$A" || exit 1; done'
collie work run --max 9 --tries 3 --timeout 3600 --budget 21600 \
  --gate 'bash scripts/ci/lint.sh && bash scripts/ci/check-architecture.sh'
```

A2.3 gera a lista de remendos; os consertos viram a onda 6, montada a partir dela.
