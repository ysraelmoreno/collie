# Memória no Cursor: início de sessão mais rico + consulta por tarefa — design

Status: **rascunho para o dono** (ask 63f428c3; escopo reduzido pelo dono no ask fbc719bd: opções 2 e 3). Sem código
de produto. As chamadas de gosto estão em “Minhas chamadas (conferir)”.

## Intenção e porquê

O Collie põe memória do projeto no contexto dos agentes. No Claude isso acontece **a cada prompt** (hook
`UserPromptSubmit`); no Cursor só **no início da sessão** (`sessionStart` do plugin). Numa sessão longa de Cursor a
memória fica velha: não chega o que é relevante para a tarefa nova, nem regra nova do usuário, nem “memória retirada”.
O dono quer fechar essa diferença com duas peças: (2) um `sessionStart` mais rico e mais focado, e (3) uma consulta
pelo MCP que o agente faça no começo de cada tarefa, barata e o mais automática possível.

Fracasso mesmo funcionando: estourar o limite do Cursor e perder **toda** a orientação; gastar token do usuário em
consultas que não trazem nada; o texto do agente virar “correção do usuário”; aumentar a superfície de texto hostil
sem rótulo; dizer ao usuário que o Cursor recebe memória a cada prompt quando não recebe.

## Estado atual (verificado no código, branch feat/doc-memory em 6973dc7, já contém main)

### O que o Claude recebe

- **Início de sessão** (`memory.hookContext`, `MemoryCommands.swift:196-229`): orientação (`CollieOrientation.text`,
  máx. 1 500 caracteres) + bloco de memória num orçamento de **4 096 bytes UTF-8** (`:215`): em compact/resume, o
  estado do trabalho e o handoff do quadro do lote; depois fixadas na íntegra, as de longo prazo, a checklist de
  armadilhas (≤ 1 200 B, ranqueada pelo foco da sessão) e um índice só de títulos do resto (`MemoryService.swift:329`),
  mais a linha de documentos. Total ≈ ≤ 5,6 KB.
- **A cada prompt** (`memory.hookRelevant`, `MemoryCommands.swift:230-262`), num orçamento de **2 048 bytes**: memórias
  retiradas (“Não vale mais”), regras empurradas pelo usuário, posts do quadro do lote endereçados a ele, comentários
  do usuário nas páginas dele, até 5 memórias relevantes ao texto do prompt ainda não injetadas na sessão (linha de
  ≤ ~500 B: rótulo, id curto, título, corpo em uma linha ≤ 300, `relevantLine` em `MemoryService.swift:937`) e trechos
  de documentos. O mesmo hook também: conta como **uso útil** as memórias do prompt anterior se este não for correção
  (`resolvePending`, `MemoryService.swift:641`), detecta correções e procedimentos e manda ao curador com a
  proveniência do usuário (`:237`), e registra eventos `injected where: prompt` / `noHit`.

### O que o Cursor recebe

- Só o `sessionStart` do plugin (`AgentLaunch.cursorPlugin`, `AgentLaunch.swift:50`; `collie hook
  cursor-session-start`, `HookCommands.swift:29-36`): **o mesmo texto** do início de sessão do Claude, no formato
  `{"additional_context": …}` (`MemoryHookClient.swift:31`). Nunca recebe o bloco por prompt: nem retiradas, nem regras
  empurradas, nem quadro, nem comentários, nem relevância por tarefa. Nenhum uso útil é contado (não há próximo prompt).
- O payload do `sessionStart` traz `transcript_path` (spike `REPORT.md` §8.2), então a sessão tem nome nos eventos.
- Pelo MCP (`plugin-collie-collie-<tool>`, decisão 9431382e) ele pode chamar `memory_search` e `memory_context`, mas:
  - `memory_context` devolve **o mesmo resumo do início de sessão**, sem foco na tarefa e sem marcar injeção.
  - `memory_search` devolve **JSON completo** por hit (corpo inteiro, caminho do arquivo, origem, datas, score): 4 hits
    medidos nesta sessão ≈ 4,5 KB. Não desconta o que a sessão já tem, não traz retiradas nem regras, e o evento
    `searched` guarda só a contagem (`MemoryCommands.swift:108`), sem ids: não dá para medir nada por memória.
- A orientação do Cursor diz só “Memory: collie memory search|save — check before re-reading.”
  (`CollieOrientation.swift`), sem pedir consulta por tarefa.
- `sessionFocus` (`MemoryService.swift:375`) já monta o foco da sessão (branch, 5 últimos commits, arquivos mudados,
  cercado), mas só ordena a checklist de armadilhas; e passa `workTitle: nil` (`:390`).

### Viabilidade no cursor-agent instalado (2026.11.13-eacade1; o spike foi em 2026.10.22)

Lido do bundle `~/.local/share/cursor-agent/versions/2026.11.13-eacade1/` e de `--help`; nenhum prompt enviado.

1. **Limite do `additional_context`: acima de 10 000 caracteres o texto é DESCARTADO inteiro, não cortado.**
   `hooks-carriers` (`4327.index.js`): `if(o.length>1e4) throw HookAdditionalContextTooLargeError`, e o chamador loga
   “additional_context exceeded max size; dropping carrier” e segue sem nada. O briefing dizia “corta”; a memória
   9431382e já dizia “descartado”, e o bundle confirma. A conta é `String.length` do JS (unidades UTF-16) depois de
   `trim()`. Como bytes UTF-8 ≥ unidades UTF-16 para qualquer caractere, **um teto em bytes UTF-8 garante o limite**.
2. Eventos que aceitam `additional_context` nesta versão (`HOOK_STEPS_SUPPORTING_ADDITIONAL_CONTEXT`): `sessionStart`,
   `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure`. Ver “Fica para depois”.
3. Documentação oficial (https://cursor.com/docs/agent/hooks): `sessionStart` aceita `env` e `additional_context`; é
   **fire-and-forget**, “the agent loop does not wait for or enforce a blocking response”. Risco: um primeiro prompt
   digitado muito cedo (summon com prompt) pode sair antes do contexto chegar. Medir com o Cursor real (tarefa D1).
4. **O cursor-agent lê o campo `instructions` do `initialize` do MCP** e manda ao modelo junto com as ferramentas
   (`index.js`: `getInstructions()` → `mcpInstructions: t.servers.flatMap(t => t.instructions)`). O `collie mcp` hoje
   não manda `instructions` (`MCPServer.swift:97-98`). É um canal fixo, por servidor, que não depende de hook. A página
   https://cursor.com/docs/context/mcp não documenta esse campo: tratar como comportamento observado, a confirmar (D1).
5. MCP de plugin carrega sem `--approve-mcps`; as chamadas de ferramenta seguem a política de aprovação do usuário
   (decisão 9431382e). Uma ferramenta que o usuário não deixou na allowlist pede aprovação a cada chamada: isso mata o
   “automático” se não for resolvido (ver Design §4).

## Metas

- No início de cada sessão do Cursor, as memórias mais ligadas ao que o terminal está fazendo, na íntegra, usando o
  espaço que o Cursor dá, **sem nunca passar do limite**.
- Uma única ferramenta que o agente chama no começo de cada tarefa e que devolve, curto e já ranqueado, o que o Claude
  teria recebido no prompt: retiradas, regras novas, quadro, comentários, memórias relevantes não vistas.
- Saber, com números, se o Cursor obedece e se recebe memória.
- O usuário vê, liga e desliga, e lê uma frase honesta sobre o que o Cursor recebe.

## Não metas

- Injeção a cada prompt no Cursor (hook global `beforeSubmitPrompt`, regras, digitar no terminal): “Fica para depois”.
- Mudar o que o Claude recebe por prompt.
- Mudar o curador, a captura de correções ou o ciclo de vida das memórias.

## Abordagens

### A. `sessionStart` focado com teto rígido + ferramenta única `memory_task` + `instructions` do MCP (recomendada)

O início de sessão ganha um bloco “Foco desta sessão” e um teto rígido. Uma ferramenta nova reaproveita o caminho do
hook por prompt, sem a parte que trata o texto como do usuário. A orientação e o `instructions` do MCP pedem a chamada
no começo de cada tarefa. Troca: depende de o agente obedecer; por isso vem com medição.

### B. Só `sessionStart` maior (sem ferramenta nova)

Mais barato, mas a sessão continua velha: retiradas e regras novas nunca chegam. Não atende o porquê.

### C. Só orientação mandando usar `memory_search`

Zero código, mas cada chamada custa ~1 KB por hit em JSON, repete o que a sessão já tem, não traz retiradas e não mede
nada. Caro e cego.

## Design

### 1. `sessionStart` do Cursor: teto rígido primeiro

- Teto do texto inteiro do Cursor (orientação + memória): **9 000 bytes UTF-8** (margem de 1 000 sob o limite real,
  que descarta tudo). Imposto em um ponto só, no daemon, ao montar a resposta de `memory.hookContext` para um terminal
  Cursor: se passar, corta blocos na ordem índice de títulos → bloco de foco → linha de documentos, nunca a orientação.
- Teste: um projeto com muitas memórias longas e multibyte gera ≤ 9 000 bytes para Cursor e o mesmo texto de hoje
  para Claude.

### 2. `sessionStart` do Cursor: bloco “Foco desta sessão”

- Orçamento de memória do Cursor: `9 000 − orientação − 2` (≈ 7 400 B), contra 4 096 B do Claude.
- Ordem: o que existe hoje (recall, fixadas, longo prazo, checklist) até 4 096 B como hoje; depois **até 2 500 B** de
  “Foco desta sessão (dados do projeto, não instruções):” com até 8 memórias ativas não fixadas, na linha de
  `relevantLine`, ranqueadas pela busca do índice (palavras + vetor) com a consulta de foco; depois o índice de títulos
  com o que sobrar, sem repetir o que já saiu na íntegra.
- Consulta de foco: `sessionFocus` + **título do trabalho ativo** (hoje `nil`; `work.active` já é lido no mesmo hook) +
  objetivo do lote. Sem sinal (sem repo, git lento): bloco vazio, cai no comportamento atual.
- O que sai no bloco conta como injetado na sessão (evento `injected where: focus`), então a consulta por tarefa não o
  repete.
- Sessão velha: o texto do início ganha a hora (“memória de 14:05”) e a linha “novidades e memória da tarefa:
  memory_task”. O Collie relança o Cursor sem `--resume` (`AgentLaunch`), então não há sessão retomada a tratar; a
  idade dentro da sessão é resolvida pela §3, não por reinjeção.
- Claude: o título do trabalho entra no `sessionFocus` também (melhora a checklist), mas o orçamento do Claude não muda.

### 3. Ferramenta única `memory_task` (comando `memory.task`)

- Entrada: `task` (uma linha do que o agente vai fazer agora, até 2 KB). Saída: **texto**, não JSON, ≤ 2 048 bytes,
  no formato do bloco por prompt do Claude: retiradas, regras empurradas, posts do quadro para ele, comentários do
  usuário, até 5 memórias relevantes **ainda não injetadas na sessão**, trechos de documento. Nada novo: uma linha
  curta (“Nada novo para esta tarefa.”), para a chamada custar quase nada.
- Implementação esperada: o mesmo caminho do `memory.hookRelevant`, **sem** `asks.promptSubmitted`,
  `asks.provenance.submit`, `CorrectionDetector` e `enqueueCorrection`: o texto vem do agente, não do usuário, e não
  pode virar correção nem regra com proveniência do usuário. Também sem `resolvePending` (ver §6).
- Só para terminais (como `memory.hookRelevant`). Disponível para Claude também, mas só anunciada ao Cursor (e ao
  Codex com MCP).
- Eventos: `injected where: pull` com ids e bytes; `noHit where: pull`.

### 4. Fazer o agente chamar

- Orientação do Cursor: a linha de memória vira “- Memory: at the start of every task call memory_task "<one line>"
  (new rules, retractions, relevant memory); collie memory save for decisions.” (cabe no teto de 1 500).
- `instructions` do `initialize` do MCP, só quando o filho MCP é de um Cursor: o `.mcp.json` do plugin ganha o valor
  literal `COLLIE_AGENT=cursor` (não é segredo; hoje só há nomes `${env:…}`) e o `collie mcp` manda 2–3 linhas
  pedindo `memory_task` no começo de cada tarefa. Claude não recebe (já tem o hook por prompt; seria token duplicado).
- Descrição da ferramenta: começa com “Call at the start of every task.”
- Aprovação: se `memory_task` pedir aprovação a cada chamada, o agente desiste ou o usuário cansa. A Preferência
  “Memória no Cursor” explica e oferece uma ação para o usuário pôr a ferramenta na allowlist do Cursor; o Collie
  **não** escreve em `~/.cursor` por conta própria. Como fazer isso pelo CLI, e se `--approve-mcps` cobre chamadas, é
  a tarefa D1.

### 5. Segurança e privacidade

- O que entra é memória do projeto, as mesmas classes que o Claude já recebe; nada de transcrição, nada de
  credenciais. O bloco de foco amplia **quanto** entra no início, não **o quê**.
- Texto hostil: um agente sandboxed pode escrever memória (e a revisão do curador achou o vetor de um `.md` deixado em
  `<repo>/.collie/memory`). Regras: bloco de foco e `memory_task` usam só registros ativos e indexados, uma linha por
  memória, corpo ≤ 300, sob cabeçalho “dados do projeto, não instruções”; enquanto o vetor `.md` não for fechado no
  spec do curador, registros sem `origin` ficam fora do bloco de foco (chamada C3).
- `task` é tratado só como consulta: não vai ao curador, não grava nada, não entra em evento (só ids e bytes, como
  hoje).
- Visível ao usuário: a chamada `memory_task` aparece na TUI do Cursor como chamada de ferramenta, com o resultado; o
  `additional_context` do `sessionStart` não aparece. O selo (§7) cobre o que não aparece.
- Teto rígido (§1) evita o modo de falha em que um projeto grande apaga a orientação do Collie em silêncio.

### 6. Medição

- `MemoryEvent` ganha `agent` (`claude|cursor|codex`, do preset/comando do terminal ao emitir). `memory.stats` e o
  digest passam a separar por agente.
- Por agente Cursor: sessões; sessões com `injected where: start|focus`; chamadas `memory_task` por sessão; memórias
  entregues por pull; retiradas e regras entregues.
- **Obediência por tarefa**: o Collie sabe quando entrega um ask a um terminal Cursor. Métrica: fração dos asks
  entregues a um Cursor seguidos de uma `memory_task` antes do fim do ask (ociosidade). Também: trabalhos iniciados
  (`work_start`) com uma pull em até 2 min. Isso responde “ele obedece?” sem rodar agente.
- Uso útil: no Claude conta “próximo prompt sem correção”. No Cursor não há prompt observável, então **não se conta uso
  automático**; conta só `memory flag --useful`. A tela de estatísticas diz isso, em vez de mostrar 0 como fracasso.
- `searched` passa a guardar ids (já não guarda texto), para comparar busca manual com pull.

### 7. UX

- Selo no cartão do terminal Cursor: “Memória: início ✓ · 3 consultas” (dos eventos da sessão); sem nenhuma consulta
  depois de 2 asks, o selo fica neutro com dica “o agente não está consultando a memória”.
- Preferências → Memória → “Memória no Cursor”: **Início + consulta por tarefa** (padrão) / **Só início** / **Desligada**.
  Desligada: sem bloco de memória no `sessionStart` (a orientação fica) e sem `instructions`; `memory_task` continua
  respondendo se chamada à mão.
- Frase honesta, na Preferência e no tooltip do selo: “No Cursor a memória chega no início da sessão e quando o agente
  consulta no começo de cada tarefa. Ela não chega a cada mensagem sua: o cursor-agent não oferece isso hoje.”

### 8. Codex (rápido)

- Hoje o Codex só tem `notify` (fim de turno); nenhuma memória entra no início, e o MCP é opt-in
  (`COLLIE_CODEX_MCP=1`, `AgentLaunch.swift:154`). Com MCP ligado, `memory_task` e o `instructions` valem igual
  (`COLLIE_AGENT=codex` no env do servidor). Sem MCP, nada muda. Se o Codex lê `instructions` do MCP não foi
  verificado: tarefa separada, depois.

## Decisões (padrão óbvio, tomadas por mim)

- Teto em bytes UTF-8 (garante o limite em UTF-16) e margem de 1 000.
- Uma ferramenta nova em vez de mudar `memory_context`/`memory_search` (quem já usa essas não muda).
- `memory_task` sem captura de correção e sem proveniência do usuário.
- Texto, não JSON, na saída de `memory_task`.
- Nada escrito em `~/.cursor` nem no repositório do usuário.

## Minhas chamadas (conferir)

- **C1. Orçamentos**: foco até 2 500 B e até 8 memórias; teto total 9 000 B. Mais foco = mais token por sessão.
- **C2. Nome da ferramenta**: `memory_task` (alternativas: `memory_brief`, `memory_pull`).
- **C3. Registros sem `origin` fora do bloco de foco** até o vetor `.md` fechar (mais seguro, pode esconder memória
  legítima antiga).
- **C4. Padrão da Preferência**: “Início + consulta por tarefa” ligado por padrão.
- **C5. `instructions` só para Cursor/Codex**, não para Claude.
- **C6. Selo** com contagem de consultas no cartão (alternativa: só no digest).

## Fica para depois

- **Hook `beforeSubmitPrompt` (global ou de plugin).** Em 2026.10.22 o do plugin não disparava (spike §8.1); só
  `~/.cursor/hooks.json` ou o do repo. **Novo:** no bundle 2026.11.13 o `beforeSubmitPrompt` aceita `additional_context`
  (`before-submit-hook-context.ts`, atrás de um `enabled`), embora a documentação ainda liste só `continue` e
  `user_message`. Vale retestar o hook **do plugin** nesta versão (D2): se disparar, é injeção por prompt sem tocar arquivo
  do usuário.
- **Regras do Cursor** (`.cursor/rules` com `alwaysApply`, `~/.cursor/rules`, `AGENTS.md`): texto fixo, escrito em
  arquivo do usuário ou do repo; não pesquisado a fundo.
- **Digitar no terminal**: rejeitado; texto digitado pode cair num diálogo e virar resposta (pitfall CF2BA1E0 e
  memória do projeto sobre texto injetado virando resposta de AskUserQuestion).
- `preToolUse`/`postToolUse` também aceitam `additional_context`; mesmo problema de não disparar via plugin em 2026.10.22.

## Riscos

- O agente ignora a orientação e não chama `memory_task`: a medição (§6) mostra; o plano B é o `beforeSubmitPrompt`
  do plugin, se D2 der certo.
- Aprovação por chamada torna a pull inviável na prática (D1).
- `sessionStart` fire-and-forget pode perder a corrida com o primeiro prompt de um summon (D1).
- O formato do bundle muda a cada versão; o comportamento do `instructions` não é documentado.

## Verificação

- Testes filtrados (nunca a suíte inteira): teto de 9 000 B com memórias multibyte; bloco de foco ordenado por
  branch/título do trabalho; nada repetido entre foco e `memory_task`; `memory_task` não chama provenance nem curador;
  texto “Nada novo” quando não há nada; evento `pull` com ids; `instructions` só com `COLLIE_AGENT=cursor`.
- Passo do dono com o Cursor real (D1, D2).

## Tarefas (lista independente; o plano detalha)

1. Teto rígido de 9 000 B no texto do `sessionStart` do Cursor + teste.
2. Título do trabalho e objetivo do lote no `sessionFocus`.
3. Bloco “Foco desta sessão” no início do Cursor (depende de 1 e 2).
4. Comando `memory.task` + ferramenta MCP `memory_task` (texto, 2 048 B, deltas, sem proveniência).
5. Orientação do Cursor + `instructions` do MCP com `COLLIE_AGENT` (depende de 4).
6. `agent` e ids nos eventos; `memory.stats`/digest por agente; métrica de obediência por ask.
7. Selo no cartão + Preferência “Memória no Cursor” + frase honesta.
8. Codex: `COLLIE_AGENT=codex` quando o MCP está ligado (pequena, depois de 5).
- **D1 (dono, Cursor real)**: o `additional_context` do `sessionStart` chega antes do primeiro prompt de um summon; o
  `instructions` do MCP chega ao modelo; o agente chama `plugin-collie-collie-memory_task` sozinho; como aprovar a
  ferramenta uma vez.
- **D2 (dono, Cursor real)**: `beforeSubmitPrompt` do plugin dispara em 2026.11.13 e o `additional_context` dele chega.
