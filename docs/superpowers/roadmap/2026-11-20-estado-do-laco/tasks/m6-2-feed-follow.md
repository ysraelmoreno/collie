# M6.2 O feed de laços acompanha o trabalho certo

Leia `onda6.md` e o **achado A2** de `rev-onda5-report.md`. Código: `Sources/CollieClient/WorkFeed.swift` (~59 `refresh()`, ~77-82 `follow`, ~92), `Sources/CollieApp/ContextPanel.swift`, `Sources/CollieClient/DaemonClient.swift` (eventos que o app já recebe: procure o evento `work` publicado pelo daemon, "re-read with work.get"), `Tests/CollieAppTests/ContextPanelLoopsTests.swift`.

## Problema
1. Sem trabalho ativo no momento do `follow`, a função retorna e nunca mais espera: se o Pastor faz `work start`/`work run` **depois** de o dono abrir o cercado, a seção LAÇOS nunca aparece.
2. Laço já terminado no trabalho ativo: `ended` e não há espera; um segundo `work run` não é visto.
3. O histórico recarrega quando o laço acaba, antes do `work done`: o trabalho fechado depois não entra.
4. `first(where:)` pode pegar um trabalho sem laço quando há mais de um ativo no cercado.
5. `refresh()` não tem chamador.

## Fazer
1. O feed **acompanha por evento** (o evento `work` do daemon que o app já assina, ou um `work.wait`/evento `ui.*` equivalente; **nunca** polling nem `sleep`): ao chegar um evento de trabalho do cercado atual, chama `refresh()` (releitura de `work.status`), e o `follow` continua mesmo sem trabalho ou com laço terminado.
2. Preferir o trabalho **com laço rodando**; sem nenhum rodando, o mais recente com laço; só então o primeiro.
3. Recarregar o **histórico** quando chega o evento de fechamento do trabalho (`work.done`) e quando o laço termina, com coalescência (no máximo uma releitura em voo).
4. Trocar de cercado continua invalidando a geração e limpando o estado (sem vazar entre cercados).
5. Falha do daemon = estado vazio, nunca quebra o painel.

## Testes (escrever antes) — novo `Tests/CollieClientTests/WorkFeedFollowTests.swift` (ou na pasta de testes do `WorkFeed`)
Daemon falso com eventos: cercado aberto **sem** trabalho, depois `work start` + laço rodando ⇒ a seção passa a existir; laço termina e um segundo `work run` ⇒ volta a existir; `work done` ⇒ o histórico ganha o trabalho; dois trabalhos ativos (um sem laço) ⇒ escolhe o que roda; troca de cercado limpa; evento de outro cercado é ignorado; várias rajadas de eventos ⇒ uma releitura em voo. `ContextPanelLoopsTests` segue verde.
