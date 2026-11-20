# M1b.1 Rede de segurança do interpretador e decodificação tolerante

Leia `onda1b.md` e `README.md`. Código: `Sources/CollieDaemonKit/Work/WorkLoop.swift` (`attempt()` e o laço do interpretador depois de `AttemptMachine.reduce`), `AttemptMachine.swift` (`default: return (s, [])` e os `guard … else { return (s, []) }`), `Sources/CollieCore/Work.swift` (`WorkLoopState`, `Stop`, `LoopEvent`, o `init(from:)` de `Work`).

## Fazer

1. **Rede de segurança.** Depois do laço de efeitos de `attempt()`, se a fase final **não** for `finished` (um evento fora de fase foi engolido pelo `default`), faça o equivalente a `.reopen` da tarefa (volta a `open`, tentativa descontada), `endJob("loop: estado inesperado do motor")`, limpe `phase`, escreva uma nota e devolva `.stop(Stop(.internal))`. Novo código `Stop.Code.internal` (label: "estado inesperado do motor (bug); a tarefa foi reaberta"); `unknown` continua sem uso. O laço **não** passa para a próxima tarefa depois disso.
2. Troque o `default` silencioso de `reduce` por um tratamento explícito: eventos que **nunca** devem chegar fora de fase deixam o estado igual e geram o efeito `.fault(String)` (descrição curta do par fase×evento), que o interpretador transforma no passo 1. Os pares válidos não mudam.
3. Para a rede ser testável, `attempt()` (ou o laço de efeitos) recebe o produtor de eventos por uma costura mínima já existente no interpretador (por exemplo, o método `perform` ser substituível num teste); **não** adicione protocolo novo só para isso.
4. **Decodificação tolerante** em `WorkLoopState`: um `init(from:)` próprio que decodifica os campos antigos como hoje (obrigatórios continuam obrigatórios) e, para `stopReason`, `events`, `phase` e os demais campos opcionais **mais novos**, usa `(try? c.decodeIfPresent(...)) ?? nil`; `events` é decodificado **elemento a elemento**, descartando só o malformado. Um `WorkLoopState` antigo e um com subcampo de forma errada (`stopReason` como string, `events[i].attempt` como string, um `LoopEvent` sem `at`) continuam produzindo um `loop`, com o campo ruim `nil` ou o elemento ruim descartado. O `Codable` de saída não muda.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopRobustnessTests.swift`

Rede: um evento fora de fase (via a costura do passo 3) reabre a tarefa, não a deixa `inProgress`, fecha o job, devolve `internal` e o laço **para**; o caminho normal não passa pela rede. `reduce`: os pares fase×evento inválidos geram `.fault` e não mudam o estado. Decodificação: `stopReason` como string, `events` com elemento sem `at`, `events` como objeto em vez de lista, e `phase` com valor desconhecido: o `loop` sobrevive; um JSON gravado pelo daemon anterior (sem os campos novos) decodifica igual a antes.
