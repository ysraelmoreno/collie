# T6.4 Seção HISTÓRICO (últimos 20)

Leia `README.md`, `T6.2`, `T6.3`. Código: `Sources/CollieApp/ContextPanel.swift`.

## Fazer
1. Seção **HISTÓRICO · n** abaixo de LAÇOS (ou de Lotes se não houver laço): os **últimos 20** (do `work.history` do cercado atual), cada linha em duas linhas: título; "21/11 02:02 · 4/6 feitas · 1h54". A cor do resultado diz o desfecho (tudo feito, com adiadas, parado). Sem filtro. **Aparece só se há ao menos 1 item**; vazio = sem seção.
2. Mais de 20 existem? Mostra 20 e uma linha discreta "mais antigos no Work" que abre o painel Work existente (sem criar tela nova).
3. Clicar numa linha dispara o detalhe (T6.5; aqui só o gancho: `onOpenHistory(id)` no `ShellContext`, com ação vazia testável até a T6.5).
4. Atualiza por `work.wait`/troca de cercado (já no feed da T6.2). Sem polling.

## Testes (escrever antes) — novo `Tests/CollieAppTests/ContextPanelHistoryTests.swift`
Seção só com ≥ 1 item; exatamente 20 itens quando há 30; ordem do mais recente; texto das duas linhas; cercado trocado muda a lista; o gancho é chamado com o id certo; a seção LAÇOS e a HISTÓRICO convivem e na ordem certa.
