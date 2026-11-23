# U5: catraca genérica (ratchet)

Spec geral: `docs/superpowers/specs/2026-11-23-fabrica-para-usuarios-design.md`, seção U5. Depende da U1 (`factory.static.ratchets` já existe no esquema:
`{name, measure, baseline}`).

"O número só pode melhorar" como recurso do Collie. Hoje: `scripts/ci/lint.sh` + `scripts/ci/lint-baseline.txt` e `scripts/ci/ci-skip.txt`. NÃO altere
esses scripts nem os testes deles (`scripts/ci/test-lint.sh`, `test-run-tests.sh`); a migração fica para depois. Esta tarefa só cria o recurso genérico e
prova que ele daria o mesmo veredito.

## Núcleo puro: `Sources/CollieCore/Ratchet.swift`

- `Ratchet.Baseline`: mapa de chave (texto sem espaço, por exemplo `regra caminho`) para contagem inteira >= 0, com `parse(_ text: String)` e
  `render()` determinísticos (ordenados; formato de linhas `<chave...> <n>`, o último campo é o número; linha vazia e `#` comentário ignorados).
- `Ratchet.compare(baseline:, current:) -> Verdict`: `.same`, `.improved([Change])` (algo caiu ou saiu: a catraca pede para baixar o baseline),
  `.worse([Change])` (chave nova ou número maior). `worse` vence `improved` quando há os dois. `Change` tem chave, antes, depois.
- `Ratchet.lowered(baseline:, current:) -> Baseline?`: o novo baseline quando só houve melhora; `nil` se houve piora (nunca sobe sem razão registrada).
- `Ratchet.raise(baseline:, to:, reason:) -> Result`: subir só com `reason` não vazio (até 200 caracteres, sem controle); devolve o baseline novo e uma linha
  de registro `# <data ISO>: <chave> <antes> -> <depois>: <razão>` para o arquivo. A data entra como parâmetro (puro).
- Modo lista (para o `ci-skip`): `Ratchet.compareList(baseline: [String], current: [String])`: a lista só pode encolher; item novo é piora.

## Comando: `collie factory ratchet <check|update|raise> <nome>` (`--reason` no raise)

Em `Sources/CollieDaemonKit/FactoryCommands.swift` (se a U3 já criou, acrescente; senão crie), no mesmo padrão de leitura segura da U3. O comando lê o
perfil (`factory.static.ratchets` de `collie-work.json`), roda `measure` UMA vez, em processo limitado como o laço roda checks (veja como
`WorkLoop`/`BoundedProcess` rodam o check; reuse, sem sandbox nova), interpreta a saída como linhas `<chave> <n>` (modo contagem), compara com o arquivo de
`baseline` e responde: `check` (código 0 igual, 1 pior, e se melhorou diz para rodar `update`), `update` (só grava se melhorou; piorou: recusa),
`raise` (grava com razão). Escrita do baseline é atômica (temporário no mesmo diretório, `rename`), caminho confinado ao projeto (sem `..`, sem link
simbólico no destino).

## Testes (`Tests/CollieDaemonKitTests/RatchetTests.swift`)

Parse/render ida e volta; igual, melhorou, piorou, chave nova, os dois ao mesmo tempo; `lowered` nil quando piora; `raise` sem razão recusa e com razão
devolve a linha de registro; lista só encolhe; comando: `update` não grava quando piora; destino com `..` recusado; baseline gravado atomicamente (sem
temporário sobrando).

## Prova de paridade (sem tocar nos scripts atuais)

`scripts/ci/test-ratchet-parity.sh`: com um repositório temporário pequeno (como `test-lint.sh` monta o dele), roda `scripts/ci/lint.sh` e o novo comando
sobre a MESMA medição e baseline e confere o mesmo veredito (igual, melhorou, piorou). Se rodar o comando exigir daemon, faça o teste de paridade no
nível puro: um teste em `RatchetTests` que alimenta `compare` com as saídas do `lint.sh` do repositório de fixture (copie 3 casos de `test-lint.sh`).
Escolha a forma que não precise de daemon nem de `sandbox-exec`.

Check: `scripts/check-fabrica-loop.sh u5`. Commit ao final, só os arquivos da tarefa.
