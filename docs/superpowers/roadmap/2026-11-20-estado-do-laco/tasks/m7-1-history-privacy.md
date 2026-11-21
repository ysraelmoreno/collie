# M7.1 A página do histórico não vaza para outro cercado e não acumula versões

Leia `onda7.md` e o **achado A1** de `rev-onda6-report.md`. Código: `Sources/CollieDaemonKit/ArtifactCommands.swift` (~220 `artifacts.addAgent(page:…, paddockId: nil, …)`, ~19-25 `artifact.list`, ~487 o `path` na linha, `artifact.get`), `RemoteSurface.swift` (~22), `Sources/CollieApp/HistoryPage.swift` (o ramo do histórico), `Tests/CollieAppTests/HistoryDetailOpenTests.swift`.

## Problema
O detalhe do histórico é gravado como artifact **sem cercado e sem pasta**: `artifact.list` devolve tudo a qualquer chamador (inclusive o `path` da `source.html`), então um agente do cercado Y lê título, notas, tarefas e motivo de parada de um trabalho do cercado X, contornando o isolamento do `work.history`. As páginas também aparecem soltas na lista de Prévias do dono. Cada clique com o painel fechado cria mais uma versão (até 8 MiB), sem limite.

## Fazer
1. Gravar com `paddockId` = **cercado do trabalho** e `inFolder` fixo `Histórico` (crie a pasta se a API permitir; senão registre o limite e use a pasta padrão do cercado).
2. `artifact.list`/`artifact.get`: artifacts com origem `history-*` só são devolvidos ao **admin/app** e a terminais **do mesmo cercado** do artifact; os outros não os veem (nem o `path`).
3. O ramo do histórico **substitui** a versão do mesmo artifact (mesma fonte) em vez de acumular `r<N>`; no máximo 1 versão guardada por trabalho.
4. O app continua abrindo a Prévia por `artifact:` e mostrando texto fixo em falha.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/HistoryArtifactPrivacyTests.swift`
Daemon real de teste com dois cercados: o terminal do cercado Y **não** lista nem lê o artifact `history-*` do cercado X (nem o `path`); o terminal do cercado X e o app admin sim; abrir o mesmo detalhe 3 vezes deixa **uma** versão; artifacts comuns não mudam de comportamento (regressão). `HistoryDetailOpenTests` segue verde.
