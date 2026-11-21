# M6.5 Pontas da revisão da Onda 5

Leia `onda6.md` e os **achados A5, A6, A7 e A9** de `rev-onda5-report.md`. Código: `Work/WorkLoop.swift` (~99 janela de avisos, ~586 `endNotice`, `reportEnd`), `CollieOrientation.swift` (~19) e `LoopCommand` (passo 5), `Sources/CollieDaemonKit/Memory/SessionUsage.swift` (~47 `TokenCount.model`), `WorkArchiveFiles.swift` (~18, ~21), `Sources/CollieApp/OpenPanelSheet.swift` (~36, ~196).

## Fazer
1. **A5:** no modo `end`, um aviso de **adiada** retido na janela de 60 s não pode esperar horas: ao passar uma tarefa **feita** (que não gera aviso), ou no início de cada tentativa nova, **esvaziar o retido** se a janela já passou (relógio injetável). O aviso final continua sem passar pela janela.
2. **A6:** a orientação do Pastor e o `/collie:loop` mandam `collie work wait --timeout 540` (ou o MCP `work_wait`) e dizem para **rodar em segundo plano** quando a ferramenta de shell tem limite de 2 a 10 min; sem prometer 3600 em primeiro plano. Limite de 1500 caracteres em todos os níveis.
3. **A7:** `TokenCount.model` só entra se passa em `CollieSettings.isLoopModel` (o regex de id de modelo), senão `nil`.
4. **A9:** `createDirectory` de `work-archive` aplica 0700 também numa pasta que já existe (e corrige o modo); o prune remove `.tmp` órfãos com mais de 1 h (relógio injetável); no `OpenPanelSheet` um HTML fora do projeto mostra "a página precisa ficar dentro do projeto" (texto fixo) em vez da mensagem genérica, e o `NSOpenPanel` abre em `directoryURL` = a worktree do cercado.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/Onda5NitsTests.swift` (e um caso de UI no mesmo arquivo se couber, senão em `Tests/CollieAppTests/OpenPanelSheetTests.swift`)
Duas adiadas em < 60 s seguidas de feitas ⇒ o retido sai na tentativa seguinte (relógio falso); orientação dentro do limite e sem `--timeout 3600`; modelo inválido do transcript ⇒ nil; pasta de archive pré-existente com modo 0755 ⇒ vira 0700; `.tmp` antigo removido e recente poupado; mensagem fora do projeto. Suítes anteriores verdes.
