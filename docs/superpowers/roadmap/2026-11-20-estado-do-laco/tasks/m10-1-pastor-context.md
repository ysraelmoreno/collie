# M10.1 Ciclo de vida do contexto do Pastor

Leia `onda10.md` e a proposta P3 de `aval-lacos-report.md`. Código: `Sources/CollieDaemonKit/Memory/ContextAdvice.swift` (limite por tamanho de arquivo, 20 MB), `Memory/SessionUsage.swift` (lê `usage` do transcript), `WorkStatusText.loopEnded`, `WorkCommands.swift` (`work.history`).

## Fazer
1. **Contexto real, não tamanho de arquivo.** `ContextAdvice` passa a medir o contexto da **última** chamada do transcript (entrada + cache criado + cache lido), lendo só o rabo do arquivo (últimos ≤256 KB, só números, mesma checagem `TranscriptChunk.allowed`). Dois limites: **aviso** em 150 mil e **forte** em 250 mil tokens; o aviso sai uma vez por 2 h por nível (mantém `every`), e o forte sobe um nível. O texto continua fixo (só o número varia) e diz o caminho: "leia a passagem de turno".
2. **Passagem de turno.** Quando um laço termina (`loopEnded`) o daemon grava `<raiz>/handoff/<paddock>.md` (um arquivo por cercado, sobrescrito, ≤4 KB, 0600): trabalho, tarefas (feitas/adiadas), commits curtos, decisões e armadilhas novas (títulos e ids da memória, nunca corpo), e a próxima onda prevista **se** o roadmap do repositório a citar. Só dados que o daemon já tem. Novo comando `collie work handoff` imprime esse arquivo; o aviso do item 1 o cita.
3. **`collie memory stats`** ganha o contexto atual e o máximo do Pastor por sessão (números só), para medir o ganho.

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/PastorContextLifecycleTests.swift`
Transcript falso com `usage` → níveis nos limites exatos (149 999, 150 000, 250 000); um aviso por nível por janela; caminho não permitido (symlink, FIFO) → sem aviso e sem leitura; o arquivo da passagem: criado ao fim do laço, sobrescrito, modo 0600, sem corpo de memória, ≤4 KB mesmo com muitas tarefas; `work handoff` sem arquivo diz que não há; o fake aplica a regra real (sem relógio de parede).
