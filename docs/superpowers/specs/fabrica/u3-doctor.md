# U3: `collie factory doctor`

Spec geral: `docs/superpowers/specs/2026-11-23-fabrica-para-usuarios-design.md`, seção U3. Depende da U1 (`FactoryProfile`, já feita: `Sources/CollieCore/FactoryProfile.swift`).
Somente leitura, determinístico, sem LLM, nunca executa o gate nem comando algum do projeto: só lê arquivos.

## Divisão

1. **Núcleo puro** em `Sources/CollieCore/FactoryDoctor.swift`: `FactoryDoctor.score(_ s: Snapshot) -> Report`. `Snapshot` é um valor com o que o leitor
   juntou: `ProjectWorkConfig?` (com `factory`), texto dos scripts citados por `gate`/`precheck`/`smoke`/`areas` (até 20 arquivos, 64 KB cada, já
   truncados), lista de caminhos do projeto até uma profundidade (para achar CI, personas, catraca, `docs/fabrica/personas`), texto dos arquivos de CI
   (`.github/workflows/*.yml`, `Makefile`), e `BaitResults?` (vazio por ora; a U4 preenche). `Report`: lista de `LayerScore` na ordem da pirâmide
   (`static`, `judge`, `verification`, `review`, `prose`, `guardrails`), cada um com `score` 0 a 3, `evidence: [String]`, `nextAction: [String]` e um
   `rating` (`FRACO` para 0 e 1, `OK` para 2, `FORTE` para 3). Regras e pesos como funções puras pequenas, uma por pergunta, cada uma com teste.
2. **Leitor + comando**: `collie factory doctor [--json] [--min <0-3>]` (comando do daemon, no padrão de `work.config` em
   `Sources/CollieDaemonKit/WorkCommands.swift` e da `CommandSpec` em `Sources/CollieProtocol/Commands.swift`; arquivo novo
   `Sources/CollieDaemonKit/FactoryCommands.swift`). Reutilize as regras de leitura segura de `WorkConfigFile` (sem link simbólico, arquivo regular,
   limites de tamanho, sem `..`); o leitor de scripts usa as mesmas regras. Saída em texto: tabela por camada (nota, rating, evidência, próxima ação);
   `--json`: o `Report` codificado. Código de saída: 0 se toda camada tem nota >= `--min` (padrão 1), senão 1 (use a convenção do CLI para erro de
   verificação que já existe; veja como `work` sinaliza falha).

## Regras por camada (heurísticas determinísticas)

- **static**: gate ausente = 0. Gate que é só `build`, `swift build`, `tsc --noEmit`, `cargo check`, `go build`, `npm run build` ou `make` sem runner de teste
  (`test`, `pytest`, `jest`, `vitest`, `go test`, `cargo test`, `swift test`, `xcodebuild test`, `gradle test`) = FRACO (nota 1). Nota sobe com: gate que roda
  testes, `precheck`, `smoke`, `areas` não vazio, catraca (`factory.static.ratchets` ou arquivo de baseline), regras de arquitetura
  (`factory.static.architecture`), e o CI citar o mesmo comando do gate. Evidência cita o arquivo e o trecho.
- **judge** (isolamento do juiz): gate/precheck/smoke que citam script versionado no repositório contam como lidos do commit base (o motor já lê do base):
  avise quando o gate cita script fora do repositório ou em caminho ignorado pelo git (`.gitignore`), e quando um check de tarefa típico só faz `grep` no
  arquivo que a tarefa cria (procure nos scripts `check-*.sh` um corpo que é só `grep`/`test -f`): FRACO. `collie-work.json` ausente = 1.
- **verification**: `factory.verification.scenarios` não vazio sobe a nota; sem cenário = 0 (a F3 ainda não existe: mensagem "sem verificação em
  runtime ainda"); área de UI sem cenário avisa.
- **review**: personas em `factory.review.personas` e arquivos correspondentes em `docs/fabrica/personas` ou no caminho de personas do repositório; sem
  personas = 0; `threshold` e `callOwner` definidos sobem.
- **prose**: `factory.prose.traps` vazio = 1 (sem armadilha nomeada não há o que converter); cada id listado conta; a nota nunca passa de 2 sem pelo menos
  uma armadilha convertida em check (não há como saber offline: deixe em 2 no máximo e diga isso na evidência).
- **guardrails**: `budgetSeconds` e `maxTries` definidos, `destructive` não vazio, `land` explícito; sem `guardrails` = 1.
- `BaitResults` presente com isca que passou derruba a nota da camada que deveria pegá-la em 1 (campo `escapedBaits: [String: Int]` por camada; vazio
  por ora, testado com valor injetado).

Determinismo: a mesma `Snapshot` dá o mesmo `Report`, ordem estável, sem relógio nem aleatoriedade.

## Testes

`Tests/CollieDaemonKitTests/FactoryDoctorTests.swift` (Swift Testing): projeto vazio; projeto com gate que só compila marcado FRACO na camada static (critério
de aceite 3 do design); projeto com gate de testes, catraca e CI igual sobe; script fora do repositório avisa; `--min` e código de saída; `--json`
decodifica de volta; determinismo (duas chamadas iguais); isca escapada derruba a camada; leitor recusa link simbólico e arquivo grande (reaproveite o
padrão de `WorkConfigTamperTests`). Registro do comando na tabela de comandos (existe teste que confere a tabela: acompanhe-o).

Check: `scripts/check-fabrica-loop.sh u3`. Commit ao final, só os arquivos da tarefa.
