# M5.4 Contabilidade de tokens por tentativa

Leia `onda5-economia-de-tokens.md`. Código: `Sources/CollieProtocol/HookPayload.swift` (`transcriptPath`), `Sources/CollieDaemonKit/Memory/TranscriptChunk` (`allowed` vetta o caminho antes de ler), `Work/WorkLoop.swift` (fim da tentativa), `Sources/CollieCore/Work.swift` (`LoopEvent`, `WorkTask`), `WorkStatusText.swift`.

## Fazer
1. Ao dispensar o agente de uma tentativa, ler o transcript **dele** (caminho vetado por `TranscriptChunk.allowed`; arquivo especial/symlink recusado como nos outros pontos) e somar **só contagens** do campo `usage` das respostas do assistente, **sem duplicar** a mesma resposta (por id): `input`, `output`, `cacheWrite`, `cacheRead`, nº de respostas e o modelo. **Nunca** guardar conteúdo.
2. Guardar por tentativa num campo **opcional e tolerante** (`LoopEvent` do veredito ou `attempts[]` da tarefa) e o total do trabalho; mostrar no `work status` (`tokens: 1,2 M (índice) · 14 msgs`) e deixar disponível para o resumo do trabalho fechado.
3. Índice relativo documentado e **configurável como constantes** (entrada 1, escrita de cache 1,25, saída 5, leitura de cache 0,1), rotulado "relativo", nunca como custo em dinheiro. Falha ao ler (arquivo sumiu, grande demais: limite de 64 MB lidos, em streaming): sem número, sem erro, sem travar o laço.
4. `collie work usage [--limit N]`: lista os últimos trabalhos do cercado com o índice total e por tarefa (só contagens).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/TokenUsageTests.swift`
Transcript de teste com respostas repetidas (mesmo id) ⇒ soma uma vez; sem `usage` ⇒ zero; arquivo ausente/FIFO/symlink/grande demais ⇒ sem número e sem erro; nada de conteúdo no estado nem no status; decodifica estado sem o campo; o comando `work usage` coerente com CLI/MCP/`Commands.swift`.
