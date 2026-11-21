# M11.1 `AskTests` fora do caminho crítico: relógio injetável nos limites do ask

Leia `onda11.md` e a proposta P1 de `aval-suite-report.md`. Medida: `AskTests` (53 testes, `.serialized`) leva **179 s** sozinha e define o tempo do check do laço (~3,9 min); 8 testes somam ~110 s de esperas reais (22 s, 21 s, 20 s, 13 s, 12 s, 11 s…).

## Fazer
1. Ache onde o ask espera por tempo de verdade (cap de espera, `heldCap`, timeout de turno, espera de hook perdido, "turn takes ~3.5 s"): `rtk proxy grep -rn "Task.sleep\|Duration\|timeout" Sources/CollieDaemonKit | grep -i ask`, e os testes de `Tests/CollieDaemonKitTests/AskTests.swift` com `timeout:` alto.
2. Passe esses limites por um valor **injetável** (campo em `DaemonConfig` ou parâmetro com padrão igual ao de hoje, como já se faz para outros tempos do daemon: siga o padrão que existir) e, nos testes, use 50 a 200 ms. **O comportamento de produção não muda**: mesmos padrões, mesmo caminho de código; só o número vem de fora.
3. Margens **relativas** nos testes (o limite do teste é uma fração do que o teste espera), nunca absolutas apertadas: o laço roda sob carga. Sem `sleep` novo.
4. Reduza `AskTests` a no máximo ~40 s no total sem remover nenhum caso: cada teste mantém a sua asserção; só encurta a espera.

## Testes
`Tests/CollieDaemonKitTests/AskClockTests.swift` (novo): o ask com limite injetado de 100 ms expira no caminho certo (cap, turno, hook perdido); com o padrão (sem injeção) o valor é o de hoje (compare as constantes); o fake aplica a regra real. As suítes `AskTests`, `RemoteAskTests`, `AskSubmitRetryTests` seguem verdes.

## Check
`swift test --disable-sandbox --skip MemoryEventEmissionTests --filter AskClockTests --filter AskTests --filter RemoteAskTests --filter AskSubmitRetryTests` (leia `Test run with N tests` e confirme que `AskTests` ficou ≤ 40 s). Registre no commit o antes/depois do tempo de `AskTests`.
