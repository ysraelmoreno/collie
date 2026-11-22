# M5.5 Conselho de contexto grande no Stop hook

Leia `onda5-economia-de-tokens.md` e `M5.2`. Código: `Sources/collie/HookCommands.swift` e `MemoryHookClient.swift` (o hook `claude-stop` recebe `transcript_path`), `HookPayload.transcriptPath`, `TranscriptChunk.allowed`.

## Fazer
1. No Stop hook do **Shepherd** (terminal que tem laço/agentes ligados), medir o **tamanho do transcript** (só `stat` do arquivo vetado; sem ler conteúdo). Acima de **20 MB** (constante), junto da resposta do Stop, acrescentar **uma** linha curta de conselho: `Contexto grande (N MB): cada turno relê ~esse contexto. Considere uma sessão nova; as decisões estão na memória e nos docs.`
2. **No máximo uma vez a cada 2 h** por terminal (relógio injetável) e nunca no mesmo turno do pedido de memória da M5.2 (um só texto por Stop).
3. Falha ao medir: não diz nada. O texto não carrega nada do transcript.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/ContextAdviceTests.swift`
Arquivo abaixo/acima do limite; uma vez por 2 h (relógio falso); coexistência com o pedido da M5.2 (só um texto); caminho fora do permitido/FIFO ⇒ silêncio; a linha tem tamanho fixo e sem conteúdo.
