# T6.5 Detalhe no canvas (Prévia gerada do resumo)

Leia `README.md` e `T6.4`. Código: `Sources/CollieApp/Shell.swift` / `ShellContext` (como abrir painéis), `Sources/CollieApp/OpenPanelSheet.swift`, o plug-in Prévia (`collie panel open preview --file`; veja como o app o abre), `Sources/ColliePlugins/WorkPanel.swift` (o resumo existente).

## Fazer
1. **`HistoryPage.html(for: WorkArchive) -> String`** (puro): uma página HTML **autônoma** (CSS inline com os tokens do tema claro/escuro por `prefers-color-scheme`, sem script, sem recurso externo): cabeçalho (título, cercado, branch, abertura, fechamento, duração, motivo de parada), tabela de tarefas (estado, tentativas, commits curtos, razão do adiamento), e a **linha do tempo** completa (hora, tarefa, tipo, detalhe). Se `reconstructed` ou `truncated`, um aviso.
2. **Escape obrigatório:** todo texto do trabalho (títulos, razões, notas, nomes de agente, detalhes de evento) passa por um único escape de HTML (`& < > " '`); nenhum desses textos vai para atributo sem escape, nem para `href`/`src`/`style`. Um `<script>`, `"><img onerror>` ou `javascript:` no título aparece **como texto**.
3. `onOpenHistory(id)`: pede `work.history --id`, gera a página, grava em `<cache do app>/history/<id>.html` (atômico; nome só de UUID validado, nunca de texto do trabalho) e abre uma **Prévia no canvas** nesse arquivo (o mesmo caminho do "Abrir painel", sem inventar um plug-in). Reabrir o mesmo detalhe reaproveita o painel já aberto. Falha do daemon: um aviso curto na seção, nada de crash.

## Testes (escrever antes) — novo `Tests/CollieAppTests/HistoryPageTests.swift`
Escape (títulos com `<script>`, aspas, `javascript:`, `&amp;`, quebra de linha, emoji), página sem `<script`, sem `http`, sem `src=`/`href=` externos; tabela e linha do tempo com 500 eventos; avisos `truncated`/`reconstructed`; o caminho do arquivo é só `[0-9a-f-]{36}.html`; o gancho gera e abre uma vez (host falso do painel).
