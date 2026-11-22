# M6.1 O detalhe do histórico abre de verdade

Leia `onda6.md` e os **achados A1 e A8** de `rev-onda5-report.md`. Código: `Sources/CollieApp/HistoryPage.swift` (~99-112), `Sources/CollieCore/PreviewFile.swift` (~21, a página precisa ficar dentro do projeto), `PanelCommands.swift` (preview, `projectRootForPanel`), `ArtifactCommands.swift` (`artifact.add`, `source`/nonce, nova versão da mesma fonte), `Tests/CollieAppTests/HistoryPageTests.swift`.

## Problema
O app grava a página em `~/Library/Caches/Collie/history/<id>.html` e abre uma Prévia com `file:` nesse caminho absoluto: o daemon recusa (fora do projeto) e o clique mostra o erro bruto com caminhos. Os testes usam um `open` falso.

## Fazer
1. Abrir a página como **artifact** (o daemon já serve `artifact:`): `artifact.add` com a página gerada e uma **fonte estável por trabalho** (por exemplo `history-<uuid do trabalho>`) para que reabrir o mesmo detalhe vire a **próxima versão do mesmo artifact**, nunca um artifact novo a cada clique; depois abrir a Prévia com `--artifact <id>`. Sem arquivo no cache do app (apague o código de gravação em `~/Library/Caches`; não deixe arquivos para trás).
2. A nota de falha mostra **texto em português fixo** (`Não foi possível abrir o histórico`), **nunca** `e.message` do protocolo nem caminhos.
3. A página ganha `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">` (defesa em profundidade: sem script nem rede mesmo se um escape faltar um dia).
4. Reabrir o mesmo detalhe reaproveita o painel se ainda aberto.

## Testes (escrever antes) — novo `Tests/CollieAppTests/HistoryDetailOpenTests.swift`
Com um **daemon falso que aplica a regra real** (use `PreviewFile.resolve` de verdade, não um `open` que aceita tudo): abrir por `file:` fora do projeto é recusado (prova do defeito), abrir por `artifact:` funciona; dois cliques no mesmo trabalho usam a **mesma fonte** (uma versão nova, não dois artifacts); a nota de falha não contém `/`, `Users`, `invalidArgs` nem a mensagem do protocolo; a página tem a CSP e nenhum `<script`/`http`; nada é gravado em `Caches`. `HistoryPageTests` segue verde (ajuste só o que dependia de gravar arquivo, e diga no commit).
