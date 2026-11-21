# Revisão Onda 3d, Onda 5, T6.1 e Trilho 2 (0719153..12375f1)

**Bloqueia a instalação? Não.** Não achei falha de segurança nem perda de dados no caminho comum. Mas três coisas falham na prática e devem ser corrigidas antes do push: o detalhe do HISTÓRICO nunca abre (A1); o feed do Trilho para de acompanhar o trabalho (A2); o `git clean` do portão lê nomes de arquivo como padrão (A3).

Método: só leitura, código fixado com `git show 12375f1:<arquivo>` e `git diff 0719153..12375f1`. Os testes do laço contam como verdes (checks cumulativos). Rodei só `scripts/ci/lint.sh` ("lint ok") e `scripts/ci/check-architecture.sh` ("ok"). Não rodei build nem test.

---

## Achados, do mais grave ao menos

### A1. O detalhe do HISTÓRICO (T6.5) nunca abre no app real. Corrigir antes do push.
- `Sources/CollieApp/HistoryPage.swift:107` grava a página em `~/Library/Caches/Collie/history/<id>.html`.
- `HistoryPage.swift:112` abre uma Prévia com `file:` igual a esse caminho absoluto.
- Do lado do daemon, `PanelCommands.swift` (preview) chama `PreviewFile.resolve(f, projectRoot:)`. Esse método recusa qualquer página fora do projeto (`Sources/CollieCore/PreviewFile.swift:21`, "a página precisa ficar dentro do projeto"). A raiz usada é a worktree do cercado (`projectRootForPanel`, quando o chamador é o app). O `servable` também recusa componente com ponto, então gravar em `.collie/…` dentro do projeto também não serve.
- **Cenário:** um clique numa linha do HISTÓRICO resulta em `invalidArgs`. A seção mostra "Não foi possível abrir o histórico: a página precisa ficar dentro do projeto /…/paddocks/x: /Users/…/Caches/…". Isso é a mensagem bruta do protocolo, com caminhos absolutos (`HistoryPage.swift:99`).
- **Como confirmei:** li `PreviewFile.resolve` e `projectRootForPanel`. Os `HistoryPageTests` usam um `open` falso, então nunca passam pelo daemon.
- **Correção sugerida:**
  - (a) gravar a página como artifact (`artifact.add`) e abrir com `artifact:` (o artifact já é aceito e servido); ou
  - (b) uma fonte própria da Prévia servida pelo daemon a partir do archive (`history:<uuid>`).
  - Em qualquer caso, a nota não deve repassar `e.message`.

### A2. O feed do Trilho (T6.2) para de acompanhar e escolhe o trabalho errado. Corrigir antes do push.
- `Sources/CollieClient/WorkFeed.swift:77-78`: se não há trabalho ativo no momento do `follow`, a função retorna e nunca mais espera.
- `WorkFeed.swift:82`: se o trabalho ativo tem um laço já terminado, `ended` é true e não há espera.
- `WorkFeed.swift:92`: o histórico é recarregado logo que o laço acaba, antes de o Pastor fechar o trabalho.
- `refresh()` (`:59`) não tem nenhum chamador em `Sources`.
- **Cenários:**
  - (1) O dono abre o cercado, e só depois o Pastor faz `work start` e `work run`: a seção LAÇOS nunca aparece até trocar de cercado ou reconectar.
  - (2) Um segundo `work run` no mesmo trabalho, depois de um laço terminado: mesmo efeito.
  - (3) `work done` depois do laço: o HISTÓRICO não mostra esse trabalho.
  - (4) O cercado tem mais de um terminal com trabalho ativo (outro Claude, ou um trabalho implícito aberto pelo primeiro TodoWrite de um agente): `first(where:)` (`:77`) pode pegar um trabalho sem laço, e LAÇOS fica oculto enquanto um laço roda.
- **Como confirmei:** leitura do código e `git grep` sem chamadores de `refresh`. Os `ContextPanelLoopsTests` usam um `work.status` falso com um único trabalho que já está rodando.
- **Correção sugerida:**
  - Preferir o trabalho com `loop.state == .running`.
  - Sem trabalho, ou com o laço terminado, continuar acompanhando: um `work.wait` sem `--since` não cobre a falta de trabalho. Dá para usar o evento `work` que o daemon já publica (`remoteEvents`, "re-read with work.get") ou um evento `ui.*` equivalente, e chamar `refresh()` nele.
  - Recarregar o histórico quando chegar o evento de fechamento.

### A3. O `git clean` do lixo do portão (M3d.3) trata nomes como pathspec. Corrigir antes do push (perda de arquivo do dono).
- `Sources/CollieDaemonKit/Work/LaneIntegrator.swift:182`: `git clean -q -f -- <nomes>`. Depois de `--`, o git ainda lê cada nome como **pathspec**: glob (`*`, `?`, `[...]`) e magia (`:(…)`, `:/`).
- **Cenário:** o portão deixa `pages/[id].js`, ou `coverage-*.txt` com nome literal. O pathspec `pages/[id].js` também casa com `pages/i.js` e `pages/d.js`, que podem ser arquivos não rastreados do dono, e o `git clean -f` apaga esses arquivos de vez. Um nome literal `*` apagaria todos os não rastreados não ignorados.
- **Como confirmei:** semântica documentada do pathspec do git. O `hash-object --` (`:186`) recebe caminhos literais, então o hash não protege.
- **Correção (uma linha):** `git --literal-pathspecs clean …`, ou prefixar cada nome com `:(literal)`.
- **Relacionado (ponytail declarado em `:149`):** um arquivo novo que o dono cria **durante** o portão conta como do portão e é apagado se não for mexido. É raro (o dono foi avisado para não editar), mas é apagamento definitivo. Mover para `<.git>/collie-gate-leftovers/` em vez de apagar eliminaria o risco.

### A4. Trabalho fechado com laço rodando: o resumo imutável guarda só ~20 eventos, não "o diário inteiro". Corrigir antes do push.
- `Sources/CollieDaemonKit/Work/WorkStore.swift:252`: `enforce` corta `loop.events` para 20 sempre que `closedAt != nil`, **mesmo com o laço rodando**.
- A escrita que fecha o trabalho (`work.done` não recusa laço rodando, `WorkCommands.swift:223`) já sai cortada. Cada escrita seguinte do laço corta de novo.
- Quando o laço termina, `closes()` (`:39`) dispara o resumo, mas o diário em memória já tem no máximo 20 eventos mais os da última escrita.
- **Teste que mascara:** `WorkArchiveTests.aWorkClosedUnderARunningLoopIsSummarizedWhenTheLoopEnds` **atribui** `events(150)` na escrita final. O laço real só acrescenta eventos, então o teste não reproduz o caso real e o comentário de `closes` ("with the whole journal") não vale.
- **Correção:** não cortar enquanto `loop?.state == .running` (condição `w.closedAt != nil && w.loop?.state != .running` em `:252`). Ajustar o teste para acrescentar eventos em várias escritas.

### A5. Aviso de tarefa adiada pode esperar horas (M5.1). Nit+, barato.
- `Sources/CollieDaemonKit/Work/WorkLoop.swift:99`: um aviso dentro da janela fica retido "até o próximo aviso".
- No modo `end` (o novo padrão), a tarefa feita retorna em `endNotice` (`:586`) **antes** de passar por `notices.offer`, então nunca esvazia o que está retido.
- **Cenário:** duas tarefas adiadas com menos de 60 s entre elas (comum com `--parallel`), seguidas de várias horas de tarefas feitas. O segundo aviso de adiada só chega com o fim do laço.
- O fim do laço lista tudo, então nada se perde, mas a adiada existe para o Pastor agir cedo. Um daemon que cai também perde o que estava retido; o aviso de `daemonRestart` lista as tarefas, então o efeito é baixo.
- **Correção:** em `reportEnd`, oferecer à janela também as feitas do modo `end` como "flush" (sem linha própria), ou esvaziar o pendente no início de cada tentativa nova se a janela já passou.

### A6. O conselho "work wait --timeout 3600" não cabe no Bash do Claude Code. Nit (fluxo).
- `Sources/CollieDaemonKit/CollieOrientation.swift:19` e `LoopCommand` passo 5: a ferramenta Bash do Claude Code tem timeout padrão de 2 min e máximo de 10 min. Em primeiro plano, o `collie work wait --timeout 3600` é morto no 2º minuto.
- A M3d.1 limpa bem o wait órfão (EOF cancela, o pid morre), então não há vazamento. Mas o Pastor refaz a espera a cada 2 min, que era o desperdício que a M5.6 queria tirar.
- **Sugestão:** "work wait --timeout 540 (ou MCP work_wait)", ou dizer para rodar em segundo plano. Ver se o `work_wait` via MCP tem limite próprio no cliente.

### A7. `TokenCount.model` é texto livre e sem limite. Nit.
- `Sources/CollieDaemonKit/Memory/SessionUsage.swift:47`: o modelo vem do transcript e vai cru para `WorkTask.tokens.model` (work.json) e para o JSON de `work usage`. Não aparece no texto do status nem no archive.
- O caminho é vetado por `allowed`, e o conteúdo é escrito pelo Claude Code. Um agente fora do sandbox, porém, pode forjar um `.jsonl` sob `projects/` e mandar o Stop hook à mão com o próprio token.
- **Correção:** limitar com `CollieSettings.isLoopModel` (ou o equivalente de `ClaudeModel.validate`), senão nil.

### A8. A página do histórico não tem CSP, e o cache não é limpo. Nit.
- Escape conferido, sem furo (ver "sem achado"). Como defesa em profundidade, um `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">` em `HistoryPage.html` fecha script e rede mesmo se um escape faltar no futuro.
- `~/Library/Caches/Collie/history/*.html` (notas, falhas, commits) acumula sem limpeza. Isso perde o sentido se A1 for para artifact.

### A9. Detalhes menores (nits)
- `WorkArchiveFiles.swift:35` (`latest`): cada `work.history` lê e decodifica todos os archives (até 200 × 1 MB) na fila de disco. Hoje só é chamado no `follow`, no fim do laço e em `--id`. Se A2 passar a recarregar por evento, vale um índice.
- `WorkArchiveFiles.swift:18`: `createDirectory` só aplica 0700 quando cria a pasta. Uma pasta pré-existente fica com o modo dela. Arquivos 0600 por `createFile`: ok. Um `.tmp` deixado por um crash entre `createFile` e o `unlink` (`:21`) nunca é removido (o prune ignora nomes com ponto).
- `UsageLimit.swift:40` (`after`): uma linha vazia depois de `trimmed` conta como borda (`allSatisfy` sobre vazio). O cursor `❯` de uma caixa de entrada vazia também é removido pelo `trimmed`. Hoje o rodapé ou a statusline do Collie abaixo da caixa impedem o falso positivo, e ainda é preciso 10 s de silêncio e estar na fase `.turn`. O falso positivo só para o laço (não conta tentativa, nada é digitado). Aceitável. Exigir que o menu tenha a linha "1." da opção anterior acima reduziria mais.
- `ContextAdvice` (M5.5): `contextAdvisedAt` só existe em memória (`CommandRouter.swift:114`). Um reinício do daemon pode repetir o conselho uma vez antes das 2 h. Inofensivo.
- `OpenPanelSheet.swift:36`: um HTML escolhido fora do projeto cai em `invalidArgs` e mostra "Não foi possível abrir o painel com essas opções.". A regra de acesso está certa (recusa, sem contorno), mas a mensagem devia dizer que a página precisa estar no projeto. O `NSOpenPanel` (`:196`) poderia abrir em `directoryURL` igual à worktree do cercado.
- `work.history` para um terminal (`WorkCommands.swift:396-406`): o escopo é o cercado inteiro, conforme a spec T6.1. Isso é mais largo que `work.get`/`work.list`, que valem só para o próprio terminal e os alcançáveis. Um terminal não-Pastor lê títulos, notas e falhas dos trabalhos fechados de outros terminais do mesmo cercado, e no pasto, de todo o pasto. Está conforme a spec; confirmar com o dono se é isso que ele quer.

---

## Áreas examinadas sem achado (e como)

- **M5.4, privacidade:** `SessionUsage.attempt` chama `TranscriptChunk.allowed` antes de abrir. A verificação:
  - exige caminho absoluto `.jsonl`;
  - usa `lstat` para recusar symlink no último componente;
  - usa `realpath` sob `projects/` contra diretório com symlink.
  - Depois, `lines` abre com `O_NOFOLLOW|O_NONBLOCK` (FIFO não trava), confere `fstat` como regular e aplica o limite de 64 MB antes e durante a leitura (retorna nil).
  - Tudo roda em `offPool`, fora do actor, e o laço nunca espera erro.
  - Só contagens e modelo chegam ao estado. `label`, `tokensLine`, `usage`, `WorkSummary` e o diário não têm conteúdo. O archive não leva tokens.
  - `work usage` usa `target()`/`visible` (o próprio terminal e os alcançáveis) e filtra pelo cercado do alvo. Outro cercado não aparece.
- **T6.1:**
  - O id de `--id` só é comparado, nunca vira caminho.
  - O nome do arquivo vem do `UUID` do `Work`. `all(in:)` só aceita `<uuid>[-n].json`.
  - A escrita é atômica e imutável: arquivo temporário seguido de `link()`. `EEXIST` passa ao número seguinte, e um nome existente nunca é sobrescrito.
  - Reabrir e fechar grava `-2`. O teste confere os bytes do primeiro arquivo.
  - A retenção apaga só nomes de archive.
  - `fitted` garante ≤ 1 MB, e a timeline tem 500 eventos com `truncated`.
  - Trabalho antigo é reconstruído. A decodificação é tolerante (`Lossy`).
  - O `namer` roda sob o `lock` do store sem deadlock: o actor é reentrante e `archiveNames` é síncrono.
  - Escopo: o terminal fica no próprio cercado (`paddock` é ignorado). O app vê o cercado que nomear, ou qualquer um por `--id`.
  - `clearHistory` remove a pasta.
- **T6.5, escape:** todo texto do trabalho passa uma vez por `esc` (`& < > " '`) e só cai em conteúdo de elemento, inclusive `<title>`. Atributos são só literais. Não há `href`/`src`/`script`. O `<br>` junta textos já escapados. O nome do arquivo é `UUID(uuidString:)` em minúsculas. Reabrir reaproveita o painel se ele ainda existe.
- **M5.6:** `admin.loop-model` está entre os `admin.*`, que só o app assinado usa. O regex `^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$` não deixa `-` inicial.
  - `--model` explícito vence, e já é validado por `ClaudeModel.validate` (`WorkLoopCommands.swift:67`).
  - A preferência só vale para agente Claude e passa de novo pelo summon (`ShepherdCommands.swift:99`, `ClaudeModel.validate`), então um `preferences.json` editado à mão também é barrado.
  - No argv, o modelo vai por `quote()` (aspas simples) em `-lc`.
- **M5.2:** em qualquer erro ou campo ausente a resposta é `(nil, nil)` e nada bloqueia. Em Stop continuado não há pedido nem conselho.
  - `askedAt` é por trabalho (logo por terminal), persiste no work.json, tem relógio injetável (`now:`) e só o daemon grava.
  - "Commit do laço" é decidido pelo sha curto da evidência e dos eventos `commitSeen`/`integrated`, cujo `detail` é o sha, nunca o texto.
  - Com o laço rodando, o pedaço não é marcado e o pedido sai depois do fim.
  - O ContextAdvice só usa `stat` (`lstat` depois de `allowed`), com texto fixo.
- **M5.3:** exige agente parado (10 s sem saída) **e** fase `.turn` com agente. Nada é digitado.
  - O ask é cancelado de verdade: `withTaskCancellationHandler` no `AskCoordinator.ask`, então o `withTaskGroup` não espera o timeout.
  - O trecho é ≤ 80 caracteres, uma linha, sem CSI nem controle.
  - `.uncount` e `.dismiss` acontecem. `Code` desconhecido vira `.unknown`, e o histórico e o app tratam o código como texto.
- **M5.1:** o laço novo usa `end`. Um laço antigo (com `notify` nil) mantém o comportamento de `task` (`endNotice` compara com `.end`). Adiada, parada e fim nunca são suprimidos: só atrasados (A5). O aviso final não passa pela janela. A orientação está dentro de 1500 caracteres (testes de orientação ajustados).
- **M3d.1:**
  - Só `work.wait` é cancelável por EOF. O read source continua armado e suspende no EOF, sem laço quente.
  - `handler` é zerado no `finish`.
  - Não há half-close nos clientes: nenhum `shutdown(SHUT_WR)` em `Sources`.
  - Pid com `kill(pid,0)` e `EPERM`: o reuso de pid está declarado e coberto pelo EOF.
  - O token por wait evita o contador de M3c.2 dessincronizar.
  - `lastToolCall` derruba um wait em segundo plano.
- **M3d.3**, fora de A3:
  - O registro só acontece com `ran && kept.isEmpty`, e só os novos depois do portão (`made(loose)`). Os `loose` anteriores nunca entram.
  - A remoção só acontece se o arquivo continua não rastreado e com o hash igual. Um arquivo mexido é poupado e anotado.
  - Há sweep no fim do laço só sem ninguém trabalhando.
  - Um "untracked would be overwritten" de arquivo do dono para com `kept`/nota.
  - `ls-files -z` é seguro com espaço e newline. O `-` inicial é coberto por `--`.
- **Trilho 2:**
  - `LoopSection`/`HistoryRow` são puros.
  - Não há `sleep` no feed (só no código de teste).
  - Não há troca entre cercados: a geração é invalidada e o estado é limpo no `follow`.
  - O `work.wait` do app vai com `caller` nil e não conta como espera do Pastor.
  - O erro bruto não aparece no diálogo Abrir painel (`failureText`), mas aparece na nota do histórico (A1).
  - A Compacta e os Ajustes ficaram intactos: só a seção "Modelo dos agentes" foi acrescentada em Laços.
  - `ContextPanel` só aparece no Trilho.
- **Testes (`git diff -- Tests/`):** nenhuma asserção relaxada sem troca equivalente.
  - `LaneIntegratorWaitTests`: "never removed" virou "removido no fim". É a mudança de M3d.3, com o motivo comentado.
  - `LaneIntegrationTests` ganhou o caso do formatter que muda o conteúdo.
  - `LoopNotifyTests` perdeu o helper com `sleep` e relógio de parede (bom). O host falso usa `Date() + skew`.
  - Relógio de parede novo só em espera limitada nos testes do app (`settle`, 200 × 10 ms) e em `Task.sleep(60/3600)` de dublês que só servem para segurar o wait até o cancelamento. Aceitável. O teste fraco é o de A4.

---

## Melhorias de fluxo ou desenho (separadas)

1. **A1, em vez de cache:** gerar o detalhe como artifact. Isso dá Prévia, exportação e comentários de graça, e tira o arquivo solto do cache.
2. **Feed por evento:** o daemon já publica `{"t":"work","id":…}` a cada mudança. Assinar esse evento no app, em vez de um `work.wait` por trabalho, resolve A2 e o caso de vários trabalhos ativos com uma assinatura só.
3. **`work.history`:** guardar um índice pequeno (`index.json` com as linhas de listagem) ao gravar o archive, para não ler 200 arquivos por chamada.
4. **Linha da orientação (A6):** recomendar uma espera em primeiro plano que caiba no limite da ferramenta do agente (540 s) ou a versão MCP.
5. **`--literal-pathspecs`:** passar por padrão em todo `host.git` do motor que recebe nomes vindos da árvore (`clean`, `diff -- <files>`). É mais barato que auditar cada chamada.
