# Revisão Onda 13 (`collie-work.json`, painel de app em branco) — somente leitura

**Bloqueia a instalação? Não.** Nenhum caminho deixa o agente da tentativa escolher o próprio portão ou pré-check do laço em curso nem do próximo; os achados são um check montado que pode passar sem ter passado (A1), divergências de texto e de UX e um teste que já não testa o que diz.

Referência: o brief pede `dad6ce8`, mas M13.4 (4aec4c1, 7cc0667, dc962a8) **não** é ancestral de `dad6ce8`; entrou pelo merge `b92b81d` e está em `57133a1` (HEAD de feat/trust-roadmap). M13.1–M13.3 lidos em `dad6ce8`; M13.4 lido em `57133a1`. Linhas abaixo: `dad6ce8` para M13.1–3, `57133a1` para M13.4.

## Achados (do mais grave ao menos)

### A1. `composeCheck` junta com ` && ` sem agrupar: `||`, `;` ou `#` numa área ou no `smoke` muda o resultado — corrigir antes do push
`Sources/CollieCore/ProjectWorkConfig.swift:91-99` (`parts.joined(separator: " && ")`).
- `areas: {"ask": "swift test --filter AskTests", "quadro": "scripts/q.sh || true"}`, `--area ask,quadro` → `ask && q || true` = `(ask && q) || true`: **a falha de `ask` some** e o check passa sempre. O mesmo com `;` na 2ª área ou no `smoke` (`ask && a; b` sai com o status de `b`).
- `"ask": "swift test --filter A # rápido"` → o `#` **descarta em silêncio** as áreas seguintes e o `smoke`.
- Sozinho, cada comando faz o que diz; quem muda o sentido é a composição.
- Confirmado: `sh -c 'false && echo B || echo masked'` → `masked`, exit 0; `sh -c 'true # c && false'` → exit 0.
- Não é escalada (o cartão mostra o texto montado), mas é o Collie montando um check que pode passar sem ter passado. Conserto: `parts.map { "( \($0) )" }.joined(separator: " && ")` (com isso um `#` dá erro de sintaxe, ou seja, falha fechada), ou recusar `#` na parse. Teste: 1ª área `false`, 2ª `true || true` → o check montado, rodado com `sh -c`, falha; um `#` não esconde o `smoke`.

### A2. `work config` mostra a árvore, `work run` usa o HEAD, sem aviso quando os dois divergem — corrigir antes do push
`Sources/CollieDaemonKit/WorkConfigCommands.swift:74-89` (sempre "(árvore de trabalho)") × `WorkLoopCommands.swift:136-147` (`loopFileDefaults` lê `HEAD`).
- Cenário: o dono cria ou edita `collie-work.json` e não commita. `work config` mostra `gate: X` como efetivo, mas `work run` roda **sem portão** (arquivo ausente no HEAD = `.absent`, sem `warning`) ou com o gate antigo. O teste `WorkConfigTamperTests.runIgnoresAnUntrackedFile` confirma que não sai aviso.
- A spec (onda13.md) pede que `work config` diga "de onde veio: base `<sha curto>` ou árvore". Hoje só diz árvore.
- Conserto barato: `work config` lê também `HEAD` e mostra "difere do commit HEAD (o laço usa o do commit)". `work run` põe um `warning` quando o arquivo da árvore difere do HEAD ou não está commitado.
- Na mesma linha: `--area` (`WorkCommands.swift:269-276`) monta o check a partir da **árvore**, não da base. Não é escalada (quem chama pode passar `--check`, e o cartão mostra o check), mas é uma terceira fonte. Vale ao menos documentar.

### A3. Painel: "Iniciando <app>…" para sempre quando o serviço diz `running` mas não responde — corrigir antes do push (barato)
`Sources/ColliePlugins/WebPluginPanel.swift:633-642` (em `57133a1`): o texto depende só de `committed`.
- Antes da M13.4, um serviço que nunca responde (porta errada no manifesto, processo que sobe e não escuta) mostrava "X não está respondendo em 127.0.0.1:porta". Agora, como nada chegou a fazer commit, mostra "Iniciando X…" mesmo **depois** do evento `running`, cujo `reloadPage` falha de novo. O dono não vê mais que o serviço não responde, nem em que endereço.
- Confirmado lendo o código: `receive("running")` → `reloadPage` → `load` → `didFailProvisionalNavigation` com `committed == false` → "Iniciando…". Nenhum teste cobre esse caso: `serviceDownAfterLoadSaysNotResponding` só cobre o caso depois do commit.
- Conserto: guardar `sawRunning` (ou `loadsAfterRunning > 0`) e usar o texto "não está respondendo" depois de um `running`.

### A4. `WorkAreaTests.flagsWinOverTheFile` passa sem testar o que diz — corrigir antes do push
`Tests/CollieDaemonKitTests/WorkAreaTests.swift:~141-149`: grava o arquivo com `writeConfig` (não rastreado) e não o commita. Depois da M13.3 o `work run` só lê o HEAD, então o arquivo nunca entra e o cartão mostra os valores das flags de qualquer jeito. A regra "a flag vence" ficou sem teste (a M13.3 passou `runTakesGateAndPrecheckFromTheFile` para `commit`, mas esqueceu este). Conserto: `commit(...)` em vez de `writeConfig`.

### Nits
- N1 `WorkLoop.swift` `configTampered` (~805): qualquer spec que **cite** `collie-work.json`, mesmo "não mexa no collie-work.json", libera o arquivo inteiro. É a mesma regra de substring do guard do portão (`tampered`), então está "igual ao guard", como pedido, mas é larga. Desenho: exigir um marcador explícito (ex.: `altera: collie-work.json`).
- N2 O tamper não vê mudanças que **só** afetam a árvore: arquivo novo ignorado por `.gitignore` (`ls-files --exclude-standard`), `update-index --skip-worktree`, ou `COLLIE-WORK.JSON` com outro caso, que no APFS o `lstat` de `read(root:)` acha mas o pathspec literal não. Nada disso chega à base (`ls-tree` exige o nome exato e um blob 100644/100755), então o gate do laço fica a salvo. Só `work config` e `--area` (que leem a árvore) são afetados; ver A2.
- N3 `configTampered`: um git que falha reprova a tentativa ("não foi possível ver…") também em projetos **sem** `collie-work.json`. É um modo de falha novo para quem não tem o arquivo (regra "não muda em nada"). O risco é baixo: o guard do portão já faz o mesmo quando há portão.
- N4 `ProjectWorkConfig.parse`: `JSONSerialization` aceita chave duplicada (fica a última). Um revisor que lê o JSON no PR pode ver um `gate` e o Collie usar outro. O cartão mostra o valor real, por isso é nit.
- N5 `work config` devolve o caminho absoluto (`/Users/...`) em `output` e em `path`. É local e o agente já conhece o cwd, então não chega a vazar, mas "collie-work.json (raiz do cercado)" bastaria.
- N6 O aviso de cercado confiável (`WorkStatusText.loopTrusted`) diz a origem do portão, mas não a do pré-check vindo do arquivo. A spec só pedia o portão.
- N7 O commit 4aec4c1 ("test(app)…") muda **código de produto**: o fallback `compile()` grava a lista de regras em `$TMPDIR/collie-content-rules` quando o store padrão falha. Vale para os painéis de plug-in também. Só age no caminho de falha e mantém a falha fechada (nil → placeholder), então é benigno, mas está fora do escopo da M13.4 ("nenhum outro painel muda") e escondido num commit de teste.
- N8 Testes novos usam `waitFor`/`pollUntil`, que são polling com `Task.sleep` e relógio de parede. São helpers que já existiam (70 usos na main) e servem só de prazo, não de asserção de tempo, mas a spec da M13.4 pedia continuation/delegate. `AppPanelBlankTests.serviceComesUpAfterThePanelOpened` libera a porta e a toma de novo (`probe.stop()` → `RouteServer(port:)`): flake raro se outro processo pegar a porta nesse intervalo.
- N9 Lacunas de teste: tamper numa faixa (`--parallel`) e numa adoção (`resumeFrom`), apagar o arquivo (`git rm`), editar o arquivo rastreado sem commitar, `--area` com operadores (A1). `cardLimitCountsTheBuiltCheck` não passa por área nenhuma: testa `loopCardText` com um check longo, comportamento que já existia. Repositórios temporários sem `defer remove` em `WorkAreaTests` e `aBuiltCheckDoesNotFollowTheFile`.
- N10 Docs: `docs/feature-map.md` cobre M13.1 e M13.2, mas **não** a M13.3 (base + tamper, "alterou collie-work.json") nem a M13.4. A convenção só está documentada em `docs/superpowers/roadmap/.../onda13.md`; não há doc de uso fora do roadmap. CHANGELOG sem entrada da Onda 13 na branch. O padrão é ela entrar na main no merge (ex.: d90a3e2); aqui o `git diff main..` mostra "remoções" que são só a main à frente, a branch não mexe no CHANGELOG.

## Examinado sem achado (e como)
- **Base do laço (M13.3):** `read(base:)` (`WorkConfigFile.swift:29-45`): sha 40/64 hex; `--literal-pathspecs ls-tree -z -l <sha> -- collie-work.json`; nome exato depois do TAB; só blob 100644/100755 (symlink 120000 e submódulo recusados); tamanho ≤ 16 KB pelo `ls-tree` e de novo pelo blob; `cat-file blob <oid>`. Com `-z`, `core.quotePath` não interfere. O pathspec sem `/` casa só a raiz, então o mesmo nome em subpasta não entra. `dir` = raiz da worktree do cercado.
- **O gate não muda no meio do laço:** é lido uma vez em `work run` (`WorkLoopCommands.swift:79-84`), gravado em `WorkLoopState.gate`/`precheck` e mostrado no cartão antes da aprovação. A retomada depois de queda e as faixas usam o valor guardado: `loopFileDefaults` só é chamado em `work.run` (grep). O HEAD andar entre o cartão e o início não muda o que foi aprovado.
- **Tamper:** `git diff --name-only -z --no-renames <before> -- name` contra a árvore pega commit, edição rastreada e remoção; rename vira dois caminhos; arquivo novo não rastreado vem via `ls-files --others` menos `keep`. Adoção: `before = resumeFrom` (`WorkLoop.swift:241`). Faixa: `dir`/`before` da faixa. A spec é lida em `before` (o agente não se autoriza editando a spec).
- **Máquina:** `.checkDone(status: nil, broken:)` → `AttemptDecision.reason` → `retry`/`defer` com descarte, uma tentativa contada como qualquer falha, sem estado novo e sem trava. Adoção que fez tamper → `adoptionFailed` + `stopLoop`, como toda adoção que falha. `WorkLoopTests`/`AttemptMachineTests` sem diff.
- **Parse (M13.1):** limites, tipos, `version` (bool recusado), controle e `generalCategory == .format` (bidi, largura zero) recusados nos comandos; nomes de área `a-z0-9-` validados antes de virar chave ou mensagem; chave desconhecida só aviso, limpa (`RerailText.clean`) na saída. Nada é executado: `parse` é puro; `work config` só lê; o teste com `touch` confirma.
- **Leitura da árvore:** `lstat` + `O_NOFOLLOW|O_NONBLOCK` + `fstat` (TOCTOU fechado), regular, ≤ 16 KB contado no `fstat` e na leitura, raiz sem `..`.
- **Cartão e limites:** a tarefa guarda o check montado (≤ 2000, `maxWorkText`); `loopCardText` mostra `t.check` literal entre «», então os 1500 do cartão contam o check montado. `--area` + `--check` é erro; `--area` vazio dá "nenhuma área pedida"; um arquivo inválido no `work run` vira `warning` de uma linha e os padrões de hoje; a flag vence (no código: `gateFlag ?? fileConfig?.gate`).
- **M13.4, causa:** 4aec4c1 traz o teste antes do conserto; a mensagem de 7cc0667 registra a causa (hipótese 1: `reload()` sem documento que fez commit não faz nada) e que a hipótese 2 não se reproduz. Bate com o sintoma (o `running` mostrava a web view vazia). Não rodei o teste (proibido pelo brief).
- **M13.4, riscos:** sem laço de recarga (sem retry com tempo; um `load` por evento ou por clique); `NSURLErrorCancelled` ignorado só para a carga que o próprio painel trocou; `page`/`committed` zerados em `load` e `teardown`; o retry confere `gen` e a identidade da web view; `didCommit` só conta para a web view atual. `page` só é definido com `origin != nil`, depois da lista de regras e com a URL do próprio `load` (origem certa). `didFailProvisionalNavigation` exige `origin`, então plug-ins com `ui/` local não mudam. O `running` com a página já carregada faz `reload()` como antes (pode recarregar uma página em uso, mas isso já existia).
- **`scripts/check-onda13.sh`:** os 8 filtros casam suítes reais (grep `struct <Nome>` em Tests); `MemoryEventEmissionTests` existe. `scripts/ci/lint.sh` exit 0; `scripts/ci/check-architecture.sh` exit 0.
- **Repositório público:** `git diff main...57133a1` sem `/Users/`, nome, e-mail ou token.

## Melhorias de fluxo e de desenho (não são achados)
- O brief devia citar o merge `57133a1`, não `dad6ce8`: a M13.4 ficou fora do commit pedido.
- Uma fonte só: o laço, o `work config` e o `--area` poderiam ler todos "HEAD, e a árvore só como comparação", com o `work config` mostrando a diferença (resolve A2 e N2 de uma vez).
- Liberação por spec: um marcador explícito na spec para o guard do portão e para o tamper juntos (N1).
- `composeCheck` com subshells (A1) e um teste que **roda** o check montado com `sh -c`, não só compara strings.
