# Auditoria A2.3: `sleep` e escapes de concorrência

PRD: `prd-a2-lint-catraca.md`. Data: 2026-11-19. Base: `scripts/ci/lint-baseline.txt` no commit `9217de1`.
Só documento: nenhum código mudou. Cada linha foi classificada lendo o código da ocorrência, não o nome do arquivo.

## Critério

**`sleep`**

- `legítimo`: a espera é o próprio requisito, ou não existe evento para esperar. Entram aqui: polling de processo
  externo (`waitpid`, `kill -0`, adb, launchctl, healthz, WebKit), backoff de reconexão ou de reinício, prazo/watchdog
  que corre contra uma continuation, debounce e limite de taxa, agenda periódica, graça entre TERM e KILL, janela de
  silêncio da saída de uma TUI externa.
- `remendo`: espera por estado que o próprio Collie produz (uma flag de actor, um contador de hook, o selo do
  `StreamHub`, um status do daemon lido pelo app) ou sincronização por tempo fixo no lugar de um sinal.

**`unsafe-concurrency`**

- `legítimo`: a sincronização existe e fica dentro do tipo (estado `private` atrás de um lock ou de uma fila serial
  própria), ou o valor é imutável e só falta `Sendable` na biblioteca (`Regex`, `ISO8601DateFormatter`, `SecIdentity`,
  `Process`).
- `remendo`: nada no tipo garante a segurança: global mutável sem lock, estado cuja regra ("só nesta thread", "depois
  do semáforo", "sob `lock`" num `static var` solto) vive só no comentário, escrita única fora do `init`.

Limites desta auditoria: a classificação é por leitura, nenhuma corrida foi reproduzida. Os riscos descritos são
o que o código permite, não falhas observadas.

Resumo:

| Regra | Linhas do baseline | Ocorrências | Legítimo | Remendo |
|---|---|---|---|---|
| `sleep` | 72 | 137 | 98 | 39 |
| `unsafe-concurrency` | 47 | 73 | 60 | 13 |

## Trocas propostas (referidas nas tabelas)

| Id | Troca | Teste que provaria |
|---|---|---|
| T1 | **Fila de espera no actor** no lugar de `while flag { sleep }`: um pequeno `AsyncGate` (lista FIFO de `CheckedContinuation`, `withTaskCancellationHandler`, prazo opcional). `release` acorda o próximo. | Suíte `AsyncGateTests`: 3 chamadas concorrentes entram na ordem de chegada; cancelar a do meio não trava a terceira; com prazo, a espera falha em `timeout` sem girar. Por uso: duas chamadas concorrentes do comando (ex.: `font.add`) terminam na ordem, com relógio de teste e zero `sleep`. |
| T2 | **Selo por evento**: o `StreamHub` publica a troca de selo num `AsyncStream` (ou `waitUntil(terminal, not: .working)` com continuation), alimentado por saída do PTY e pelos hooks, em vez do tique de 250 ms. Quem espera "parou de trabalhar" consome o evento. | `StreamHubTests`: saída + hook de fim de turno trocam o selo sem avançar relógio; `wait` devolve no mesmo passo do `turn.completed` (hoje até 450 ms depois); um turno que acaba e recomeça em < 250 ms é visto (hoje pode ser perdido). |
| T3 | **Prazo rearmado pela saída** no lugar de amostrar `lastOutputAt`: cada saída do PTY cancela e rearma um temporizador com relógio injetado; ao vencer, dispara `ready`/`quiet`. | `AskCoordinatorTests` com relógio de teste: silêncio de exatamente `readyQuiet` libera o primeiro prompt; saída 1 ms antes rearma; nenhuma janela curta é perdida. |
| T4 | **Continuation resolvida pelo evento** que já chega ao actor (hook `UserPromptSubmit`, `windowEnded`, latch de `ready`, mensagem da página), com prazo ao lado. | Por caso: o teste entrega o evento e a chamada volta sem avançar o relógio; sem evento, volta em `timeout` no prazo exato. |
| T5 | **Enter depois do eco**: esperar o texto colado aparecer na saída do PTY (evento que o Collie já recebe) e a janela do `ApprovalTracker` fechar sem diálogo antes de escrever o Enter; `submitDelay` vira só o prazo máximo. | `AskCoordinatorTests` com PTY falso: um diálogo desenhado entre a colagem e o Enter faz o Enter **não** ser escrito e o ask ser recusado/reenfileirado; sem diálogo, o Enter sai logo após o eco. |
| T6 | **Evento de status em `ui.events`**: o daemon emite `status.changed` (android, motor de design, atualização, remoto, rede, job) e o app/CLI assina; o polling fica só como reconciliação na reconexão. | `CommandRouterTests`: mudar o estado emite um evento; teste do modelo da tela: aplica o evento sem chamar `*.status` de novo. |
| T7 | **Configuração injetada** (`DaemonConfig`/parâmetro do tipo) no lugar de `static var` global. | `PaddockAppsTests` passam os valores pelo config e rodam em paralelo; `grep` não acha mais `nonisolated(unsafe) static var` nesses arquivos. |
| T8 | **Estado dentro do lock**: `OSAllocatedUnfairLock(initialState:)` (já usado em `AppServices.owners`, `BoundedProcess.live`) ou `Mutex`, de modo que o compilador prove o acesso; caixas de um valor só viram o retorno da closure ou um lock de um campo. | Compila sem `@unchecked`/`nonisolated(unsafe)`; a suíte existente do arquivo passa com Thread Sanitizer (`swift test --sanitize=thread --filter <Suite>`). |
| T9 | **Versão observada, não pausa**: `settle` repete `sync` até duas leituras seguidas darem a mesma versão/hash do documento (ou o servidor passar a informar um número de sequência), com prazo. | `DesignSystemServiceTests` com cliente falso: uma edição que chega 800 ms depois ainda entra no `publish` (hoje é perdida depois de 500 ms). |

## Regra `sleep`

### CLI e servidor MCP (`Sources/collie`)

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/collie/CLI.swift` | 1 | `Sources/collie/CLI.swift:139` | remendo | Segue um job (instalação Android etc.) chamando `*.status` a cada 1 s até `done/failed/cancelled`. O daemon sabe quando a fase muda. | T6 (stream do job) |
| `Sources/collie/MCPServer.swift` | 1 | `Sources/collie/MCPServer.swift:56` | remendo | A cada 10 s relê plug-ins e alcance para mandar `tools/list_changed`. O próprio comentário pede o stream de eventos. | T6 |

### App (`Sources/CollieApp`)

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/CollieApp/AndroidPreferences.swift` | 1 | `Sources/CollieApp/AndroidPreferences.swift:49` | remendo | A tela relê `android.status` a cada 1 s (job rodando) ou 3 s. | T6 |
| `Sources/CollieApp/CanvasViewport.swift` | 1 | `Sources/CollieApp/CanvasViewport.swift:359` | legítimo | Debounce de 500 ms antes de gravar o layout do canvas. | |
| `Sources/CollieApp/CelularPreferences.swift` | 1 | `Sources/CollieApp/CelularPreferences.swift:83` | remendo | A tela relê o estado do acesso remoto a cada 3 s. | T6 |
| `Sources/CollieApp/CollieApp.swift` | 1 | `Sources/CollieApp/CollieApp.swift:251` | legítimo | Agenda: a cada 10 min confere se já passou a hora do resumo diário de memória (no máximo um aviso por dia). | |
| `Sources/CollieApp/CursorMemoryPreferences.swift` | 1 | `Sources/CollieApp/CursorMemoryPreferences.swift:125` | remendo | O selo relê `memory.stats` a cada 30 s. Baixo risco (só atraso visual). | T6 |
| `Sources/CollieApp/DesignEnginePreferences.swift` | 1 | `Sources/CollieApp/DesignEnginePreferences.swift:27` | remendo | A tela relê `design.engine.status` em intervalo que depende do estado. | T6 |
| `Sources/CollieApp/DockView.swift` | 1 | `Sources/CollieApp/DockView.swift:77` | legítimo | Debounce de 400 ms: grava o tamanho da doca quando o arraste assenta. | |
| `Sources/CollieApp/PreferencesView.swift` | 1 | `Sources/CollieApp/PreferencesView.swift:98` | remendo | Três chamadas de status a cada 5 s só para os selos da barra lateral. | T6 |
| `Sources/CollieApp/UpdateInstallSheet.swift` | 2 | `Sources/CollieApp/UpdateInstallSheet.swift:138` | remendo | Espera os agentes pararem relendo `client.badges` a cada 5 s; `badges` já é estado observável do app. | T2 no app: observar a mudança de `badges` (`withObservationTracking`); teste do modelo: selo muda para ocioso e a instalação segue sem esperar 5 s. |
| | | `Sources/CollieApp/UpdateInstallSheet.swift:231` | remendo | A cada 10 min relê `app.update.status` para notificar versão pronta; o daemon sabe quando o download termina. | T6 |
| `Sources/CollieApp/UpdatePreferences.swift` | 1 | `Sources/CollieApp/UpdatePreferences.swift:45` | remendo | A tela relê `app.update.status`. | T6 |
| `Sources/CollieApp/UsagePopover.swift` | 1 | `Sources/CollieApp/UsagePopover.swift:22` | legítimo | Atualiza o uso a cada 5 min; o dado vem de provedor externo, não há evento. | |

### Cliente e núcleo (`Sources/CollieClient`, `Sources/CollieCore`, `Sources/CollieTerminal`)

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/CollieClient/DaemonClient.swift` | 3 | `Sources/CollieClient/DaemonClient.swift:87` | legítimo | Backoff de reconexão ao daemon (0,25 s dobrando até 2 s). | |
| | | `Sources/CollieClient/DaemonClient.swift:118` | remendo | Relê `HostConnection.status` a cada 500 ms porque a conexão não tem callback. | T4: `HostConnection` ganha `onStatus`; teste: derrubar a conexão muda `hostStatus` sem avançar relógio. |
| | | `Sources/CollieClient/DaemonClient.swift:453` | legítimo | Backoff de até 4 s para `unauthorized`/`daemonUnavailable` na troca de daemon. | |
| `Sources/CollieClient/DaemonLauncher.swift` | 2 | `Sources/CollieClient/DaemonLauncher.swift:66` | legítimo | Polling de `launchctl print` até o serviço antigo sumir (processo externo). | |
| | | `Sources/CollieClient/DaemonLauncher.swift:96` | legítimo | Nova tentativa de `launchctl bootstrap` (exit 5 enquanto o launchd desmonta o job). | |
| `Sources/CollieClient/TerminalStream.swift` | 1 | `Sources/CollieClient/TerminalStream.swift:152` | legítimo | Debounce de 100 ms do redimensionamento; só o último tamanho é enviado. | |
| `Sources/CollieCore/ClaudeRateLimits.swift` | 2 | `Sources/CollieCore/ClaudeRateLimits.swift:115` | legítimo | Polling de `waitpid(WNOHANG)` de um `/bin/sh` externo até o prazo. | |
| | | `Sources/CollieCore/ClaudeRateLimits.swift:119` | legítimo | Graça de 0,3 s entre SIGTERM e SIGKILL do grupo. | |
| `Sources/CollieTerminal/PTYProcess.swift` | 3 | `Sources/CollieTerminal/PTYProcess.swift:159` | legítimo | `waitpid(WNOHANG)` intercalado com `drain()`: um `waitpid` bloqueante travava a fila. | |
| | | `Sources/CollieTerminal/PTYProcess.swift:203` | legítimo | Nova tentativa de `write` em `EAGAIN` com prazo (contrapressão do processo externo). | |
| | | `Sources/CollieTerminal/PTYProcess.swift:228` | legítimo | Graça de 2 s entre SIGHUP e SIGKILL. | |

### Daemon: asks, comandos e laço (`Sources/CollieDaemonKit`)

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/CollieDaemonKit/AskCoordinator.swift` | 15 | `Sources/CollieDaemonKit/AskCoordinator.swift:206` | legítimo | Fim da janela de silêncio após uma entrada: varre a saída da TUI externa. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:213` | legítimo | Segunda janela: decide o estouro quando a saída continuou parada. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:379` | remendo | Amostra `lastOutputAt` a cada 50 ms para decidir `ready`; o comentário admite perder uma janela curta de silêncio. | T3 |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:473` | legítimo | Prazo do ask contra a continuation. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:550` | legítimo | Teto (`captureHoldMax`) da retenção de captura. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:578` | remendo | Até 15 voltas de 0,2 s numa thread esperando a janela do próprio `ApprovalTracker` fechar. | T4 (`windowEnded` resolve a espera) |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:582` | remendo | `submitDelay` fixo entre colar o comando e o Enter (`typeCommand`). | T5 |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:626` | remendo | `waitReady` relê a flag `ready` do próprio actor a cada 50 ms. | T4 (continuation no latch de `ready`) |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:678` | legítimo | Teto (`heldMax`) de um ask retido. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:690` | legítimo | Libera a retenção quando o agente externo fica em silêncio; o estado persiste, a amostragem de 100 ms só atrasa. Sai de graça com T3. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:761` | remendo | `repump` a cada 100 ms esperando a varredura do `ApprovalTracker` ou o silêncio. | T4 + T3 |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:797` | remendo | `submitDelay` fixo entre o texto do ask e o Enter; o comentário diz que um diálogo desenhado nesse intervalo leva o Enter. | T5 |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:813` | legítimo | Fim de turno por silêncio em terminais sem hook (shell, custom, Cursor): não há evento. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:879` | legítimo | Depois de responder uma aprovação, confere em `answerReaction` se a TUI externa tirou o diálogo da tela. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:940` | remendo | `confirmSubmit` relê `submits`/`turnEnds` (contadores de hook do próprio actor) a cada 100 ms. | T4 (o hook resolve) |
| `Sources/CollieDaemonKit/CommandRouter.swift` | 3 | `Sources/CollieDaemonKit/CommandRouter.swift:514` | legítimo | Teto de 3 s para o git do fim de turno não segurar o hook de Stop. | |
| | | `Sources/CollieDaemonKit/CommandRouter.swift:589` | remendo | `collie wait`: relê `turnEnds` e o selo do hub a cada 200 ms (o selo já é amostrado 4/s). | T2 |
| | | `Sources/CollieDaemonKit/CommandRouter.swift:615` | remendo | Avisos de fim de turno: espera o Pastor parar relendo o selo a cada 500 ms. | T2 |
| `Sources/CollieDaemonKit/StreamHub.swift` | 3 | `Sources/CollieDaemonKit/StreamHub.swift:79` | legítimo | Janela de silêncio após entrada (mesma do `AskCoordinator.swift:206`). | |
| | | `Sources/CollieDaemonKit/StreamHub.swift:81` | legítimo | Janela de estouro. | |
| | | `Sources/CollieDaemonKit/StreamHub.swift:159` | remendo | Os selos (`working`, atenção…) nascem de um tique de 250 ms. É a origem dos pollings de `CommandRouter`, `ModelCommand`, `PaddockApps` e `WorkLoop`. | T2 |
| `Sources/CollieDaemonKit/ModelCommand.swift` | 2 | `Sources/CollieDaemonKit/ModelCommand.swift:74` | remendo | `collie model --wait`: relê "em turno" (selo do hub) a cada 200 ms. | T2 |
| | | `Sources/CollieDaemonKit/ModelCommand.swift:107` | legítimo | Lê a resposta do `/model` na tela da TUI externa a cada 100 ms até o prazo. | |
| `Sources/CollieDaemonKit/Work/WorkLoop.swift` | 2 | `Sources/CollieDaemonKit/Work/WorkLoop.swift:267` | remendo | O laço espera outros terminais saírem do turno relendo `othersWorking()` (selo do hub). | T2 (via `WorkLoopHost`) |
| | | `Sources/CollieDaemonKit/Work/WorkLoop.swift:305` | legítimo | Espera o commit do agente: `git` é processo externo e não avisa. A parte `working` sai com T2. | |
| `Sources/CollieDaemonKit/Work/WorkAssistant.swift` | 5 | `Sources/CollieDaemonKit/Work/WorkAssistant.swift:53` | legítimo | Prazo da reescrita pelo modelo local (relógio injetado). | |
| | | `Sources/CollieDaemonKit/Work/WorkAssistant.swift:71` | legítimo | TTL do cache de falha. | |
| | | `Sources/CollieDaemonKit/Work/WorkAssistant.swift:96` | legítimo | Prazo da reescrita de proposta. | |
| | | `Sources/CollieDaemonKit/Work/WorkAssistant.swift:126` | legítimo | Prazo de espera na fila de perguntas (a fila em si já é de continuations). | |
| | | `Sources/CollieDaemonKit/Work/WorkAssistant.swift:141` | legítimo | Prazo da pergunta. | |
| `Sources/CollieDaemonKit/WorkCommands.swift` | 1 | `Sources/CollieDaemonKit/WorkCommands.swift:150` | legítimo | Varredura de jobs vencidos a cada 60 s (agenda). | |
| `Sources/CollieDaemonKit/Herds/HerdApplier.swift` | 1 | `Sources/CollieDaemonKit/Herds/HerdApplier.swift:27` | remendo | `while applyingHerd { sleep 100 ms }`: serialização por flag e tempo, sem ordem entre quem espera. | T1 |
| `Sources/CollieDaemonKit/FontCommands.swift` | 1 | `Sources/CollieDaemonKit/FontCommands.swift:148` | remendo | `while addingFont { sleep 100 ms }`. | T1 |
| `Sources/CollieDaemonKit/ArtifactCommands.swift` | 1 | `Sources/CollieDaemonKit/ArtifactCommands.swift:41` | remendo | `while addingSources.contains(origin) { sleep 50 ms }`; o comentário promete "uma versão nunca ultrapassa outra", mas com dois à espera a ordem de acordar é arbitrária. | T1 |
| `Sources/CollieDaemonKit/ArtifactImport.swift` | 1 | `Sources/CollieDaemonKit/ArtifactImport.swift:51` | remendo | Nome de importação já tomado: espera 100 ms e tenta o próximo (corrida de nome resolvida por tempo). | `DesignService.create` reserva o nome livre de forma atômica (recebe a função de nome); teste: duas importações concorrentes com o mesmo título saem com nomes distintos sem `sleep`. |
| `Sources/CollieDaemonKit/DesignCommands.swift` | 1 | `Sources/CollieDaemonKit/DesignCommands.swift:252` | remendo | `while designScopeBusy { sleep 100 ms }` com prazo. | T1 |
| `Sources/CollieDaemonKit/Memory/MemoryCapture.swift` | 1 | `Sources/CollieDaemonKit/Memory/MemoryCapture.swift:112` | remendo | `while capturing.contains(workId) { try? sleep 50 ms }`: sem prazo, e com a tarefa cancelada o `try?` vira laço sem pausa até a outra captura acabar. | T1 |
| `Sources/CollieDaemonKit/Memory/Consolidation.swift` | 2 | `Sources/CollieDaemonKit/Memory/Consolidation.swift:126` | legítimo | Agenda: primeira consolidação 5 min após o início. | |
| | | `Sources/CollieDaemonKit/Memory/Consolidation.swift:132` | legítimo | Agenda: confere a cada 10 min quais memórias estão devidas. | |
| `Sources/CollieDaemonKit/Memory/ConversationCapture.swift` | 1 | `Sources/CollieDaemonKit/Memory/ConversationCapture.swift:265` | legítimo | Temporizador de ociosidade (10 min sem turno) rearmado a cada Stop. | |
| `Sources/CollieDaemonKit/Memory/MemoryService.swift` | 1 | `Sources/CollieDaemonKit/Memory/MemoryService.swift:231` | legítimo | Prazo de 150 ms para o embedding não segurar o prompt. | |
| `Sources/CollieDaemonKit/Curator/Curator.swift` | 1 | `Sources/CollieDaemonKit/Curator/Curator.swift:359` | legítimo | Tique da fila do curador, com relógio injetado. | |
| `Sources/CollieDaemonKit/PluginHost.swift` | 1 | `Sources/CollieDaemonKit/PluginHost.swift:69` | legítimo | Prazo da chamada ao app contra a continuation. | |
| `Sources/CollieDaemonKit/UserEnvironment.swift` | 1 | `Sources/CollieDaemonKit/UserEnvironment.swift:94` | legítimo | Watchdog do shell de captura de ambiente (processo externo). | |
| `Sources/CollieDaemonKit/TerminalRegistry.swift` | 1 | `Sources/CollieDaemonKit/TerminalRegistry.swift:68` | legítimo | No desligamento, espera os processos dos terminais saírem (até 2 s, depois KILL). | |
| `Sources/CollieDaemonKit/OrphanReaper.swift` | 1 | `Sources/CollieDaemonKit/OrphanReaper.swift:55` | legítimo | `kill -0` nos órfãos até 2 s, depois SIGKILL. | |
| `Sources/CollieDaemonKit/UnixSocket.swift` | 3 | `Sources/CollieDaemonKit/UnixSocket.swift:87` | legítimo | Pausa de 100 ms no `accept` (recuo quando aceitar falha). | |
| | | `Sources/CollieDaemonKit/UnixSocket.swift:238` | legítimo | Prazo para fechar a conexão cujo leitor não drena. | |
| | | `Sources/CollieDaemonKit/UnixSocket.swift:283` | legítimo | Mesmo prazo em `closeAfterFlush`. | |

### Daemon: apps do cercado, design, dispositivos, rede, remoto

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/CollieDaemonKit/AppServices.swift` | 4 | `Sources/CollieDaemonKit/AppServices.swift:137` | legítimo | Prazo (`startWait`) de quem espera o serviço subir; a espera é por continuation. | |
| | | `Sources/CollieDaemonKit/AppServices.swift:192` | legítimo | Polling do health HTTP do app (processo externo). | |
| | | `Sources/CollieDaemonKit/AppServices.swift:210` | legítimo | Backoff exponencial de reinício após queda. | |
| | | `Sources/CollieDaemonKit/AppServices.swift:342` | legítimo | Varredura de ociosidade dos serviços (prazo, não evento). | |
| `Sources/CollieDaemonKit/PaddockApps.swift` | 4 | `Sources/CollieDaemonKit/PaddockApps.swift:678` | legítimo | Prazo do cartão de confirmação. | |
| | | `Sources/CollieDaemonKit/PaddockApps.swift:720` | legítimo | Backoff de reconexão do stream de eventos (SSE) do app. | |
| | | `Sources/CollieDaemonKit/PaddockApps.swift:742` | legítimo | Limite de taxa: um aviso por `noticeGap` em cada terminal. | |
| | | `Sources/CollieDaemonKit/PaddockApps.swift:743` | remendo | Espera o terminal parar de trabalhar relendo o selo a cada 500 ms. | T2 |
| `Sources/CollieDaemonKit/Design/DesignService.swift` | 5 | `Sources/CollieDaemonKit/Design/DesignService.swift:101` | remendo | `while naming.contains(nome) { sleep 100 ms }`. | T1 |
| | | `Sources/CollieDaemonKit/Design/DesignService.swift:631` | legítimo | Prazo de quem espera o slot (fila de continuations). | |
| | | `Sources/CollieDaemonKit/Design/DesignService.swift:654` | legítimo | Temporizador de ociosidade do slot. | |
| | | `Sources/CollieDaemonKit/Design/DesignService.swift:704` | legítimo | Polling do motor de design (servidor externo) até o arquivo ficar vivo. | |
| | | `Sources/CollieDaemonKit/Design/DesignService.swift:1101` | remendo | `settle`: `sync`, pausa fixa de 500 ms, `sync`; uma edição mais lenta que isso é perdida (está no comentário). | T9 |
| `Sources/CollieDaemonKit/Design/DesignSystemService.swift` | 2 | `Sources/CollieDaemonKit/Design/DesignSystemService.swift:119` | remendo | `publish` repete por 2 s porque "sem mudanças" pode ser só a edição ainda a caminho. Mesma causa do `settle`. | T9 |
| | | `Sources/CollieDaemonKit/Design/DesignSystemService.swift:392` | remendo | `claim`: `while busy.contains { sleep 100 ms }` com prazo. | T1 |
| `Sources/CollieDaemonKit/Design/FigcraftServer.swift` | 4 | `Sources/CollieDaemonKit/Design/FigcraftServer.swift:88` | remendo | `holdWhenFree`: `while holds.contains(.backup) { sleep 50 ms }` com prazo. | T1 |
| | | `Sources/CollieDaemonKit/Design/FigcraftServer.swift:144` | legítimo | `kill -0` até 2 s depois do TERM, então KILL. | |
| | | `Sources/CollieDaemonKit/Design/FigcraftServer.swift:213` | legítimo | Backoff de reinício do servidor. | |
| | | `Sources/CollieDaemonKit/Design/FigcraftServer.swift:271` | legítimo | Polling de `/healthz` do servidor externo. | |
| `Sources/CollieDaemonKit/Design/MCPStdioClient.swift` | 1 | `Sources/CollieDaemonKit/Design/MCPStdioClient.swift:116` | legítimo | Prazo da chamada ao motor contra a continuation. | |
| `Sources/CollieDaemonKit/Android/AndroidInstaller.swift` | 1 | `Sources/CollieDaemonKit/Android/AndroidInstaller.swift:579` | legítimo | Watchdog do `sdkmanager` (processo externo). | |
| `Sources/CollieDaemonKit/Devices/DeviceService+Android.swift` | 1 | `Sources/CollieDaemonKit/Devices/DeviceService+Android.swift:90` | legítimo | Polling do boot do emulador via adb. | |
| `Sources/CollieDaemonKit/Devices/DeviceService.swift` | 5 | `Sources/CollieDaemonKit/Devices/DeviceService.swift:199` | legítimo | Graça depois do último espectador sair. | |
| | | `Sources/CollieDaemonKit/Devices/DeviceService.swift:249` | legítimo | Polling de adb/simctl (dispositivos externos). | |
| | | `Sources/CollieDaemonKit/Devices/DeviceService.swift:349` | legítimo | 300 ms de silêncio do logcat encerram um crash Java. | |
| | | `Sources/CollieDaemonKit/Devices/DeviceService.swift:383` | legítimo | Backoff do observador de crashes. | |
| | | `Sources/CollieDaemonKit/Devices/DeviceService.swift:401` | legítimo | `kill -0` nos processos no desligamento. | |
| `Sources/CollieDaemonKit/Devices/DeviceSession.swift` | 1 | `Sources/CollieDaemonKit/Devices/DeviceSession.swift:149` | legítimo | Nova tentativa de conexão ao servidor scrcpy do aparelho. | |
| `Sources/CollieDaemonKit/Devices/LongProcess.swift` | 1 | `Sources/CollieDaemonKit/Devices/LongProcess.swift:166` | legítimo | Graça de 1 s entre SIGTERM e SIGKILL. | |
| `Sources/CollieDaemonKit/Devices/SimSession.swift` | 1 | `Sources/CollieDaemonKit/Devices/SimSession.swift:87` | legítimo | Amostra a memória do `axe` externo a cada 1 s. | |
| `Sources/CollieDaemonKit/Network/DeviceNetworkSetup.swift` | 1 | `Sources/CollieDaemonKit/Network/DeviceNetworkSetup.swift:161` | legítimo | Polling de `adb root` até `id -u` dar 0. | |
| `Sources/CollieDaemonKit/Network/MitmProcess.swift` | 2 | `Sources/CollieDaemonKit/Network/MitmProcess.swift:118` | legítimo | Polling da porta do mitmdump ao subir. | |
| | | `Sources/CollieDaemonKit/Network/MitmProcess.swift:127` | legítimo | Polling da porta liberar depois do stop. | |
| `Sources/CollieDaemonKit/Network/NetworkService.swift` | 2 | `Sources/CollieDaemonKit/Network/NetworkService.swift:376` | legítimo | Orçamento de tempo do detach no desligamento. | |
| | | `Sources/CollieDaemonKit/Network/NetworkService.swift:387` | legítimo | Reconciliação periódica das sessões com os aparelhos (adb). | |
| `Sources/CollieDaemonKit/Remote/RemoteGateway.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemoteGateway.swift:96` | legítimo | Prazo de 5 s para o listener de rede subir. | |
| `Sources/CollieDaemonKit/Remote/RemotePairing.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemotePairing.swift:112` | legítimo | Acorda quem espera o pareamento no prazo (expiração). | |
| `Sources/CollieDaemonKit/Remote/RemoteSession.swift` | 2 | `Sources/CollieDaemonKit/Remote/RemoteSession.swift:86` | legítimo | Prazo do `session.hello`. | |
| | | `Sources/CollieDaemonKit/Remote/RemoteSession.swift:244` | legítimo | Junta a saída do terminal e envia no máximo a cada `outEvery` (limite de taxa). | |
| `Sources/CollieDaemonKit/Sandbox/SandboxWatcher.swift` | 1 | `Sources/CollieDaemonKit/Sandbox/SandboxWatcher.swift:72` | legítimo | Backoff de reinício do `log stream`. | |
| `Sources/CollieDaemonKit/Update/UpdateChecker.swift` | 2 | `Sources/CollieDaemonKit/Update/UpdateChecker.swift:141` | legítimo | Agenda: primeira checagem 60 s após o início. | |
| | | `Sources/CollieDaemonKit/Update/UpdateChecker.swift:147` | legítimo | Agenda: a cada 12 h. | |

### Painéis (`Sources/ColliePlugins`)

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/ColliePlugins/BrowserPanel.swift` | 1 | `Sources/ColliePlugins/BrowserPanel.swift:155` | legítimo | Nova tentativa de remover o data store enquanto o processo WebContent encerra. | |
| `Sources/ColliePlugins/DeckExporter.swift` | 1 | `Sources/ColliePlugins/DeckExporter.swift:93` | legítimo | Prazo de uma chamada ao WebKit (que não cancela). | |
| `Sources/ColliePlugins/DesignPanel.swift` | 1 | `Sources/ColliePlugins/DesignPanel.swift:70` | legítimo | Prazo da sonda de GPU. | |
| `Sources/ColliePlugins/DevicePanel.swift` | 1 | `Sources/ColliePlugins/DevicePanel.swift:278` | legítimo | Junta deltas de rolagem por 150 ms antes de enviar (debounce). | |
| `Sources/ColliePlugins/DiagramCommands.swift` | 2 | `Sources/ColliePlugins/DiagramCommands.swift:112` | remendo | Relê `editorReady` (flag ligada pela mensagem da própria página) a cada 50 ms. | T4 |
| | | `Sources/ColliePlugins/DiagramCommands.swift:136` | legítimo | Prazo do conversor Mermaid. | |
| `Sources/ColliePlugins/DiagramPanel.swift` | 1 | `Sources/ColliePlugins/DiagramPanel.swift:121` | legítimo | Prazo da resposta do draw.io. | |
| `Sources/ColliePlugins/FileWatch.swift` | 1 | `Sources/ColliePlugins/FileWatch.swift:50` | legítimo | Debounce de 150 ms dos eventos do arquivo. | |
| `Sources/ColliePlugins/HTMLSnapshotter.swift` | 1 | `Sources/ColliePlugins/HTMLSnapshotter.swift:177` | legítimo | Prazo do snapshot. | |
| `Sources/ColliePlugins/NetworkPanel.swift` | 1 | `Sources/ColliePlugins/NetworkPanel.swift:197` | remendo | O painel Rede relê `device.list`/`network.status` enquanto visível. | T6 |
| `Sources/ColliePlugins/PluginPanelView.swift` | 2 | `Sources/ColliePlugins/PluginPanelView.swift:63` | legítimo | Janela de limite de taxa do refresh. | |
| | | `Sources/ColliePlugins/PluginPanelView.swift:181` | remendo | Até 1 s de voltas de 50 ms porque a chamada do host pode chegar antes do evento `.panel`. | T4: espera a chegada do painel no espelho (continuation por id, prazo de 1 s); teste: a chamada chega antes do evento e despacha assim que ele chega. |
| `Sources/ColliePlugins/PreviewPanel.swift` | 2 | `Sources/ColliePlugins/PreviewPanel.swift:147` | remendo | Relê `loads`/`failure` (ligados pelo próprio delegate de navegação) a cada 50 ms. | T4 |
| | | `Sources/ColliePlugins/PreviewPanel.swift:425` | legítimo | Nota que some da tela depois de 3 s (UI). | |
| `Sources/ColliePlugins/WebPluginPanel.swift` | 4 | `Sources/ColliePlugins/WebPluginPanel.swift:287` | remendo | Relê `ready` (a página registra o handler) a cada 20 ms. | T4 |
| | | `Sources/ColliePlugins/WebPluginPanel.swift:299` | legítimo | Prazo do comando do plug-in. | |
| | | `Sources/ColliePlugins/WebPluginPanel.swift:326` | legítimo | Prazo do snapshot da página. | |
| | | `Sources/ColliePlugins/WebPluginPanel.swift:629` | legítimo | Backoff de recarga após a página cair. | |

## Regra `unsafe-concurrency`

A contagem do lint é por linha que casa com o padrão; em `OfflineRewrite.swift` uma delas é o comentário que explica
o uso (linha 151).

| Arquivo | n | Ocorrência | Classe | O que o código faz | Troca |
|---|---|---|---|---|---|
| `Sources/collie/MCPServer.swift` | 4 | `Sources/collie/MCPServer.swift:11` | remendo | `static var initialized, lastReach` "under `lock`": a regra está só no comentário. | T8 (um `State` dentro do lock) |
| | | `Sources/collie/MCPServer.swift:12` | remendo | `static var lastSpecs`, idem. | T8 |
| | | `Sources/collie/MCPServer.swift:15` | remendo | `static var memoryTask`, idem. | T8 |
| | | `Sources/collie/MCPServer.swift:37` | remendo | `static var refreshTail`, idem. | T8 |
| `Sources/CollieCore/ClaudeRateLimits.swift` | 1 | `Sources/CollieCore/ClaudeRateLimits.swift:56` | legítimo | `Buf`: dados atrás de `NSLock`, classe privada. | |
| `Sources/CollieCore/SocketClient.swift` | 1 | `Sources/CollieCore/SocketClient.swift:137` | legítimo | `StreamClient`: leitura e escrita cada uma sob seu lock. | |
| `Sources/CollieDaemonKit/Android/AndroidDownload.swift` | 1 | `Sources/CollieDaemonKit/Android/AndroidDownload.swift:183` | legítimo | Delegate do `URLSession` com estado privado sob lock. | |
| `Sources/CollieDaemonKit/AppServices.swift` | 3 | `Sources/CollieDaemonKit/AppServices.swift:15` | remendo | `static var idle`: global mutável sem lock, existe para o teste encurtar. | T7 |
| | | `Sources/CollieDaemonKit/AppServices.swift:16` | remendo | `static var restartBase`, idem. | T7 |
| | | `Sources/CollieDaemonKit/AppServices.swift:24` | legítimo | `Owner`: `weak var` atribuído só no `init`; fica guardado num dicionário sob lock. | |
| `Sources/CollieDaemonKit/Artifacts/OfflineRewrite.swift` | 5 | `Sources/CollieDaemonKit/Artifacts/OfflineRewrite.swift:151` | legítimo | Comentário que justifica as três linhas seguintes (conta para o lint). | |
| | | `Sources/CollieDaemonKit/Artifacts/OfflineRewrite.swift:152` | legítimo | `static let` de `Regex`: valor imutável, `Regex` não é `Sendable`. | |
| | | `Sources/CollieDaemonKit/Artifacts/OfflineRewrite.swift:153` | legítimo | Idem. | |
| | | `Sources/CollieDaemonKit/Artifacts/OfflineRewrite.swift:154` | legítimo | Idem (array de `Regex`). | |
| | | `Sources/CollieDaemonKit/Artifacts/OfflineRewrite.swift:226` | legítimo | `OfflineRewriter`: relatório privado sob lock. | |
| `Sources/CollieDaemonKit/AskCoordinator.swift` | 3 | `Sources/CollieDaemonKit/AskCoordinator.swift:17` | legítimo | `PasteModeTracker`: estado privado sob lock, alimentado da fila do PTY. | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:46` | legítimo | `ApprovalTracker`: estado privado sob lock (eventos emitidos dentro do lock para manter a ordem). | |
| | | `Sources/CollieDaemonKit/AskCoordinator.swift:976` | legítimo | `AskEventSink`: `sink` privado sob lock. | |
| `Sources/CollieDaemonKit/AttentionDetector.swift` | 1 | `Sources/CollieDaemonKit/AttentionDetector.swift:25` | legítimo | `static let` de `Regex`. | |
| `Sources/CollieDaemonKit/BoundedProcess.swift` | 2 | `Sources/CollieDaemonKit/BoundedProcess.swift:21` | legítimo | `Sink`: buffer privado sob lock. | |
| | | `Sources/CollieDaemonKit/BoundedProcess.swift:45` | remendo | `Status { var value }` sem lock: a ordem escrita→leitura depende do semáforo `exited` em volta. | T8 (lock de um campo) |
| `Sources/CollieDaemonKit/CommandRouter.swift` | 1 | `Sources/CollieDaemonKit/CommandRouter.swift:6` | remendo | `WeakRouter`: `weak var` escrito uma vez na linha 284, fora de lock, depois de as closures que o leem já terem sido entregues aos serviços. | T8, ou iniciar os serviços depois do `init`; teste: evento de serviço emitido durante o `init` com TSan. |
| `Sources/CollieDaemonKit/Devices/DeviceSession.swift` | 1 | `Sources/CollieDaemonKit/Devices/DeviceSession.swift:13` | legítimo | Estado sob `lock`; escrita no socket de controle na fila `controlQ`. | |
| `Sources/CollieDaemonKit/Devices/LongProcess.swift` | 1 | `Sources/CollieDaemonKit/Devices/LongProcess.swift:19` | legítimo | `Input`: fd privado sob lock. | |
| `Sources/CollieDaemonKit/Devices/SimSession.swift` | 2 | `Sources/CollieDaemonKit/Devices/SimSession.swift:30` | legítimo | Estado sob `lock`. | |
| | | `Sources/CollieDaemonKit/Devices/SimSession.swift:252` | remendo | `StreamReader { var mjpeg }` sem lock: "só na thread do stdout" é convenção. | O leitor vira variável local da closure da thread; teste existente de `SimSession` com TSan. |
| `Sources/CollieDaemonKit/FontCommands.swift` | 1 | `Sources/CollieDaemonKit/FontCommands.swift:67` | legítimo | Delegate do `URLSession` com estado privado sob lock. | |
| `Sources/CollieDaemonKit/InputProvenance.swift` | 1 | `Sources/CollieDaemonKit/InputProvenance.swift:6` | legítimo | Estado privado sob lock. | |
| `Sources/CollieDaemonKit/Memory/ClaimChecks.swift` | 1 | `Sources/CollieDaemonKit/Memory/ClaimChecks.swift:25` | legítimo | `RepoProbe`: cache privado sob lock. | |
| `Sources/CollieDaemonKit/Memory/LifecycleRules.swift` | 1 | `Sources/CollieDaemonKit/Memory/LifecycleRules.swift:90` | legítimo | `static let` de `ISO8601DateFormatter`, só leitura depois de criado. | |
| `Sources/CollieDaemonKit/Memory/MemoryEmbedder.swift` | 1 | `Sources/CollieDaemonKit/Memory/MemoryEmbedder.swift:12` | legítimo | `Models`: `loaded` e toda chamada ao `NLEmbedding` sob lock. | |
| `Sources/CollieDaemonKit/Memory/MemoryEvents.swift` | 1 | `Sources/CollieDaemonKit/Memory/MemoryEvents.swift:63` | legítimo | `MemoryEventLog`: `lastDay` privado, só na fila serial própria. | |
| `Sources/CollieDaemonKit/Memory/MemoryProvenance.swift` | 1 | `Sources/CollieDaemonKit/Memory/MemoryProvenance.swift:16` | legítimo | `state` sob lock. | |
| `Sources/CollieDaemonKit/Memory/MemoryService.swift` | 3 | `Sources/CollieDaemonKit/Memory/MemoryService.swift:7` | legítimo | `RepoMemory`: estado privado só na fila serial (SQLite fora do pool cooperativo, de propósito). | |
| | | `Sources/CollieDaemonKit/Memory/MemoryService.swift:223` | legítimo | `Once`: continuation sob lock, retomada uma vez. | |
| | | `Sources/CollieDaemonKit/Memory/MemoryService.swift:908` | legítimo | `static let` de `ISO8601DateFormatter`. | |
| `Sources/CollieDaemonKit/Memory/ProcedureSkills.swift` | 1 | `Sources/CollieDaemonKit/Memory/ProcedureSkills.swift:100` | legítimo | `Cache`: valor sob lock. | |
| `Sources/CollieDaemonKit/PaddockApps.swift` | 1 | `Sources/CollieDaemonKit/PaddockApps.swift:202` | remendo | `static var noticeGap`: global mutável sem lock que os testes alteram com daemons rodando. | T7 |
| `Sources/CollieDaemonKit/Remote/RemoteAddress.swift` | 2 | `Sources/CollieDaemonKit/Remote/RemoteAddress.swift:96` | remendo | `static var cached` ao lado de um `static let lock`: a ligação entre os dois é só convenção. | T8 |
| | | `Sources/CollieDaemonKit/Remote/RemoteAddress.swift:120` | remendo | `Box { var data }` sem lock: a ordem depende do semáforo `done`. | T8 |
| `Sources/CollieDaemonKit/Remote/RemoteAudit.swift` | 2 | `Sources/CollieDaemonKit/Remote/RemoteAudit.swift:7` | legítimo | `RemoteAudit`: escrita do arquivo sob lock. | |
| | | `Sources/CollieDaemonKit/Remote/RemoteAudit.swift:52` | legítimo | `RemoteLimits`: baldes privados sob lock. | |
| `Sources/CollieDaemonKit/Remote/RemoteDevices.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemoteDevices.swift:39` | legítimo | Lista privada sob lock. | |
| `Sources/CollieDaemonKit/Remote/RemoteEvents.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemoteEvents.swift:7` | legítimo | `sinks` privado sob lock. | |
| `Sources/CollieDaemonKit/Remote/RemoteGateway.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemoteGateway.swift:153` | legítimo | `Once`: continuation privada sob lock. | |
| `Sources/CollieDaemonKit/Remote/RemoteIdentity.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemoteIdentity.swift:12` | legítimo | Imutável depois do `init`; `SecIdentity` é tipo CF sem `Sendable`. | |
| `Sources/CollieDaemonKit/Remote/RemotePairing.swift` | 1 | `Sources/CollieDaemonKit/Remote/RemotePairing.swift:8` | legítimo | Estado sob lock. | |
| `Sources/CollieDaemonKit/Remote/RemoteSession.swift` | 3 | `Sources/CollieDaemonKit/Remote/RemoteSession.swift:44` | legítimo | Estado sob lock, mensagens na fila própria. | |
| | | `Sources/CollieDaemonKit/Remote/RemoteSession.swift:179` | legítimo | `Attach`: classe privada usada só na fila da sessão. | |
| | | `Sources/CollieDaemonKit/Remote/RemoteSession.swift:403` | legítimo | `RemoteSessions`: mapas privados sob lock. | |
| `Sources/CollieDaemonKit/Sandbox/SandboxWatcher.swift` | 2 | `Sources/CollieDaemonKit/Sandbox/SandboxWatcher.swift:95` | legítimo | `Child { let p = Process() }`: referência imutável; `Process` não é `Sendable`. | |
| | | `Sources/CollieDaemonKit/Sandbox/SandboxWatcher.swift:110` | remendo | `Tail { var d }` sem lock: escrita numa thread, leitura depois do semáforo `errDone`. | T8 |
| `Sources/CollieDaemonKit/StreamHub.swift` | 1 | `Sources/CollieDaemonKit/StreamHub.swift:10` | legítimo | `Fanout`: assinantes privados sob lock. | |
| `Sources/CollieDaemonKit/UnixSocket.swift` | 2 | `Sources/CollieDaemonKit/UnixSocket.swift:16` | legítimo | Servidor: estado na fila própria, estatística sob lock. | |
| | | `Sources/CollieDaemonKit/UnixSocket.swift:114` | legítimo | `Connection`: leitura na fila do servidor, fila de envio sob lock. | |
| `Sources/CollieDaemonKit/WorkChatCommands.swift` | 1 | `Sources/CollieDaemonKit/WorkChatCommands.swift:137` | legítimo | `Typed`: um booleano sempre lido e escrito sob o lock. | |
| `Sources/ColliePlugins/DevicePanel.swift` | 1 | `Sources/ColliePlugins/DevicePanel.swift:86` | legítimo | `FrameSlot`: imagem privada sob lock. | |
| `Sources/CollieTerminal/PTYProcess.swift` | 1 | `Sources/CollieTerminal/PTYProcess.swift:27` | legítimo | Estado privado sob `lock`/`ioLock` e fila própria. | |
| `Sources/CollieTerminal/ScrollbackBuffer.swift` | 1 | `Sources/CollieTerminal/ScrollbackBuffer.swift:3` | legítimo | Buffer privado sob lock. | |

## Os 5 remendos de maior risco (candidatos à próxima onda)

Em ordem. O critério é o estrago quando a espera por tempo erra, não a quantidade de linhas.

1. **Enter por tempo depois de colar o prompt** — `Sources/CollieDaemonKit/AskCoordinator.swift:797`, `:582` e a
   espera de janela em `:578`. Entre o texto e o Enter passa um `submitDelay` fixo; um diálogo de aprovação desenhado
   nesse intervalo recebe o Enter, ou seja, o Collie pode aprovar algo que ninguém aprovou. Troca T5.
   Tarefa: "ask: o Enter só sai depois do eco e com a janela limpa".
2. **Selo `working` por tique de 250 ms e todos que o releem** — `Sources/CollieDaemonKit/StreamHub.swift:159`,
   `Sources/CollieDaemonKit/CommandRouter.swift:589` e `:615`, `Sources/CollieDaemonKit/ModelCommand.swift:74`,
   `Sources/CollieDaemonKit/PaddockApps.swift:743`, `Sources/CollieDaemonKit/Work/WorkLoop.swift:267`,
   `Sources/CollieApp/UpdateInstallSheet.swift:138`. Polling em cima de polling: um turno que acaba e recomeça entre
   duas amostras passa despercebido, e `wait`, os avisos ao Pastor e o laço decidem com um selo atrasado. Troca T2.
   Tarefa: "hub: troca de selo como evento; `wait`, avisos e laço consomem".
3. **Serialização por flag e `sleep`** — `Sources/CollieDaemonKit/ArtifactCommands.swift:41`,
   `Sources/CollieDaemonKit/Memory/MemoryCapture.swift:112`, `Sources/CollieDaemonKit/Design/DesignService.swift:101`,
   `Sources/CollieDaemonKit/Design/DesignSystemService.swift:392`, `Sources/CollieDaemonKit/Design/FigcraftServer.swift:88`,
   `Sources/CollieDaemonKit/DesignCommands.swift:252`, `Sources/CollieDaemonKit/FontCommands.swift:148`,
   `Sources/CollieDaemonKit/Herds/HerdApplier.swift:27`. Oito cópias do mesmo padrão: não há ordem entre quem espera
   (a versão de um artefato pode ultrapassar outra), e onde o laço usa `try?` uma tarefa cancelada gira sem pausa.
   Troca T1. Tarefa: "`AsyncGate` FIFO e as oito trocas".
4. **Prontidão e envio do prompt por amostragem** — `Sources/CollieDaemonKit/AskCoordinator.swift:379`, `:626`,
   `:761`, `:940`. O primeiro prompt de um terminal recém-criado depende de amostrar o silêncio a cada 50 ms (janela
   curta perdida = prompt preso até `readyMax`), e a confirmação de envio relê contadores de hook que já chegam como
   evento. Trocas T3 e T4. Tarefa: "ask: `ready` e `submitted` por evento, relógio injetado".
5. **Publicação do sistema de design com pausa fixa** — `Sources/CollieDaemonKit/Design/DesignService.swift:1101` e
   `Sources/CollieDaemonKit/Design/DesignSystemService.swift:119`. `settle` confia em 500 ms (mais 2 s de novas
   tentativas) para as edições de outros clientes chegarem; a que demora mais fica fora da versão publicada, sem erro.
   Troca T9. Tarefa: "design: `settle` por versão estável".

Fora dos cinco, mas barato e com efeito em flakiness de teste: os globais mutáveis
`Sources/CollieDaemonKit/AppServices.swift:15`, `:16` e `Sources/CollieDaemonKit/PaddockApps.swift:202` (troca T7),
e o `WeakRouter` de `Sources/CollieDaemonKit/CommandRouter.swift:6`.
