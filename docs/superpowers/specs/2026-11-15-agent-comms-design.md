# Comunicação entre agentes (Cursor e outros) — design

Status: tasks 1, 2, 3 e 5 implementadas (2026-11-15); task 4 parada (ver nota no fim).

## Intenção e porquê

O dono pediu um fluxo "saudável e ágil" de comunicação entre agentes, Cursor↔Cursor e Claude/outro↔Cursor. Um teste
real (2026-11-15, dois Cursors `cur-a`/`cur-b` numa tarefa que o código resolveu em ~1 min) levou ~4 min, quase tudo
de comunicação. Memória do projeto: pitfall "ask bloqueante cruzado entre agentes que se esperam gera impasse".

## Estado atual (verificado no código e no teste)

1. **Impasse com `wait`.** `AskCoordinator.ask` já recusa um ciclo (`reaches(to, from)` → `.deadlock`), mas o grafo só
   tem arestas de `ask`. `collie wait` (`CommandRouter.waitTurn`, laço de 200 ms) não entra no grafo. Foi o caso do
   teste: `cur-a` fez `ask cur-b` (bloqueante) e `cur-b` fazia `wait cur-a`; nada acusou, ambos esperaram o timeout.
2. **Resposta do Cursor por tela.** O Cursor não dispara hook de fim de turno (`--plugin-dir` só dispara
   `sessionStart`, spike 2026-11-03). `ask` a um Cursor conclui por ociosidade e devolve o raspado da tela: 400 a 580
   linhas de repintura da TUI, com a prévia mostrando o eco do próprio prompt. O caminho "por hook" existe e é
   limpo: `turn.completed` com `message` → `AskCoordinator.turnCompleted(terminal:message:)` completa o ask em voo
   com o texto. Só o Claude chama esse comando (oculto na CLI e no MCP).
3. **Pedido sem remetente.** O prompt de um `ask` entre agentes é digitado como veio (`PromptInjector.payload`),
   sem dizer quem pediu. Para o destino é igual a uma mensagem do usuário. Já a resposta chega com
   `[collie] Reply from <nome> (ask <id>):` (`AskInbox`).
4. **Fila invisível.** Um prompt digitado num Cursor ocupado vira "follow-up" na fila da TUI e só é lido no fim do
   turno; quem enviou não sabe. `ask --no-wait` informa só a entrega (`onDelivered`).
5. **Prompt de `summon` perdido** uma vez (`pr-reader`), nas outras duas chegou: intermitente, causa não confirmada
   (hipótese: digitado antes de a TUI do Cursor estar pronta; a prontidão hoje é "quieto por 300 ms" ou 10 s).

## Metas

- Um ciclo de espera entre agentes é recusado na hora com `deadlock`, também quando um lado usa `wait`.
- Um agente Cursor responde a um `ask` com um texto limpo e curto, sem raspar a tela, e o `ask` conclui na hora.
- Toda mensagem de um agente a outro diz quem enviou.
- Quem envia sabe quando a mensagem ficou na fila atrás de um turno em andamento.
- O prompt inicial de um `summon` a um Cursor chega, ou a falha é visível.

## Não metas

- Não adicionar hooks ao Cursor (o `cursor-agent` não dispara; reavaliar ao atualizá-lo).
- Não mexer no caminho do Claude (Stop hook, captura, aprovações).
- Allowlist de comandos do Cursor: decisão de segurança do usuário; fica fora (ver "Fica para o dono").
- Não criar canal novo entre terminais (o `collie lot` já existe).

## Anti-metas

- Nenhuma mensagem de agente pode parecer do usuário (o prefixo de remetente é obrigatório e não editável pelo
  remetente).
- `reply` nunca conclui o ask de outro terminal, nem responde a um diálogo de aprovação.
- A conclusão por ociosidade continua valendo: um Cursor que esquece de chamar `reply` não deixa o ask pendurado.

## Abordagens consideradas

**Resposta limpa do Cursor**
- A. **`collie reply "<texto>"`**: o prompt de um `ask` a um Cursor termina com a instrução de responder por esse
  comando. Reaproveita `turnCompleted(message:)`. Escolhida.
- B. Pedir ao Cursor que escreva a resposta num arquivo e ler o arquivo. Mais lento e sem o ciclo de vida do ask.
- C. Melhorar o raspado da tela (cortar repintura). Frágil a cada versão da TUI; não dá um texto limpo.

**Impasse**
- A. `wait` entra no grafo de espera do `AskCoordinator`; `ask` e `wait` consultam o mesmo `reaches`. Escolhida.
- B. Limitar o tempo de `ask`/`wait` entre agentes. Esconde o problema, não o resolve.

## Design

### 1. `wait` no grafo de espera

`AskCoordinator` ganha arestas de espera `(from, to)` por token: `beginWait(from:to:) throws(ProtocolError) -> UUID`
(lança `.deadlock` se `reaches(to, from)`, contando as arestas de ask e de wait), `endWait(_ token: UUID)`.
`reaches` passa a seguir as duas. `waitTurn` abre a aresta antes do laço de espera (só se não retornar na hora) e a
fecha por `defer`. A mensagem de erro é a do ask: `Deadlock: '<A>' is already waiting on '<B>'; '<B>' cannot wait
on '<A>'`. `ask` ganha a checagem contra arestas de wait, sem mudar a mensagem.

### 2. Prefixo de remetente

Em um `ask` de agente a agente (`!raw`, não do usuário, não inject, e `prompt.count > dialogAnswerMax`), o texto
digitado começa com `[collie] pedido de <nome> (ask <id curto>): `. O `Waiter.prompt` guardado continua sem o
prefixo (a conta de eco e de assinatura do Claude não muda); só `PromptInjector.payload` recebe o texto com prefixo.
`--raw` e respostas curtas a diálogos (`ask B y`) seguem exatas. O nome vem do registro de terminais, nunca do
argumento do remetente.

### 3. `collie reply`

- Comando novo `reply` (`message` posicional, obrigatório, ≤ 8 KiB), exposto na CLI e no MCP (`reply`).
- Roda no terminal chamador. Conclui o ask **em voo** destinado ao chamador, com `source: .hook` e o texto como
  saída. Sem ask em voo para o chamador: erro `notFound` ("no ask is waiting for your reply").
- Não faz `hookCapable = true`, não mexe em `idleOwed`/`turnEnds`/avisos ao Shepherd: o fim de turno do Cursor segue
  por ociosidade; `reply` só entrega o texto. Mesmo valendo para qualquer preset sem hook (codex, custom).
- Para destino `cursor` (`t.preset == .cursor`), o prompt digitado ganha a linha final:
  `(Ao terminar, responda com: collie reply "<resposta curta>")`. Não vale para `--raw`, nem para inject.

### 4. Visibilidade da fila e entrega

- `ask --no-wait` e `ask` (cabeçalho) informam `targetBusy: true` quando o destino está em turno (badge `working`
  ou, para Claude, `inTurn`): a mensagem entra na fila dele. A resposta do `ask.result` e a linha do inbox dizem
  "na fila atrás de um turno em andamento".
- Prontidão do Cursor: a prontidão do alvo `cursor` exige também que a tela tenha o campo de entrada da TUI
  (o marcador `→` do prompt) antes de digitar o prompt inicial do `summon`; teto `readyMax` de 20 s para Cursor.
  Depois de digitar, se em 5 s a tela não mostra o texto, ele é redigitado uma vez; falhando de novo, o `summon`
  devolve `delivered: false` com o motivo. **Antes disso**, reproduzir a perda (summon de Cursor com prompt, 10
  vezes, contar) para confirmar a causa; se a causa for outra, o plano para e avisa.

### 5. Orientação aos agentes

`CollieOrientation` (as linhas de `ask`/`wait`) ganha uma linha curta: "Não faça `ask` bloqueante a quem pode esperar
por você; use `--no-wait` ou `collie lot post`. Se você é Cursor e recebeu um pedido, termine com `collie reply`."
Respeita o orçamento de 1500 caracteres (a versão compacta existe).

## Decisões do usuário

- Pediu fluxo saudável e ágil, Cursor×Cursor e Claude/outro×Cursor.
- Pediu o design e o plano das melhorias 1 a 3 (reply, ciclo de espera, remetente); a entrega verificada (4) e a
  orientação (5) entram por serem pequenas e do mesmo fluxo. Dizer se prefere separar.

## Minhas chamadas (conferir)

- `reply` sem id de ask (conclui o único ask em voo do chamador).
- Prefixo em português (`pedido de <nome>`), como as demais frases de aviso.
- `reply` não latcha o modo "só por hook".
- Reproduzir a perda do prompt de `summon` antes de corrigi-la.
- A instrução de `reply` só para destino `cursor` por ora.

## Fica para o dono

- Allowlist mínima para Cursors do Collie (`collie *`, `head`, `python3 -m unittest`, `git status`): muda o que o
  agente executa sem pedir; o hook `rtk` reescreve comandos e quebra a lista. Decisão de segurança dele.

## Fica para quem construir

- Texto exato do prefixo e da linha de `reply`; o formato do campo `targetBusy`.
- Como detectar o campo de entrada do Cursor na tela (o marcador pode mudar entre versões: manter fallback por
  tempo).
- Teste vivo com dois Cursors (repetir o experimento) depois de instalar o bundle: passo do dono.

## Nota de implementação (2026-11-15)

- **1. `wait` no grafo** (`f5238f3`): `AskCoordinator.beginWait/endWait`; `waitTurn` abre a aresta só quando o alvo está
  `working` e a fecha ao sair (fim de turno, timeout ou cancelamento), sem `Task` solta.
- **2. Prefixo** (`1842307`): `[collie] pedido de <nome> (ask <id>): `. O id é o do inbox no `--no-wait` (casa com
  `Reply from … (ask <id>)`) e 8 hex do waiter no bloqueante. Nome do registro, sem controle/quebra, até 64 chars.
- **3. `collie reply`** (`8d97c08`): conclui só o ask em voo de agente ao chamador (não inject, nem usuário, nem ask já
  vencido). 1 a 8192 bytes. A linha `(Ao terminar, responda com: collie reply "<resposta curta>")` só para destino
  `cursor`, nas mesmas condições do prefixo.
- **4. Parada.** Reprodução em daemon isolado com `cursor-agent` 2026.11.13: pasta já confiável, 10/10 prompts de
  `summon` chegaram. Pasta nova: 1/1 perdido. O Cursor abre "Workspace Trust Required" ([a] Trust / [q] Quit) e as
  teclas do prompt caem no diálogo (o `a` de "Responda" aceitou a confiança). A causa não é "digitado antes da TUI
  pronta", e o `ApprovalTracker` não reconhece esse diálogo do Cursor. `targetBusy` também ficou para depois.
- **5. Orientação** (commit da task 5): o aviso de ask bloqueante vale só para quem não é Shepherd e tem pares (o
  Shepherd já está no teto de 1500 e a linha dele ensina `--no-wait`). A linha do `reply` vale para `agent == cursor`
  e, na versão compacta, vira o sufixo ` Asked: collie reply.`
