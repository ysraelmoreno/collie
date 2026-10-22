# Orq — Fase 3 — Design

Data: 2026-10-24. Autor: conversa com o usuário (brainstorming). Base: v1 completa (Fases 1 e 2, `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md`), plano 2E das pendências da v1 (`docs/superpowers/plans/2026-10-24-plan-2e-v1-followups.md`).

Marcações: **[usuário]** = o usuário disse/decidiu; **[call]** = decisão minha, para o usuário conferir; o resto é consequência direta.

---

## 1. Intenção e porquê

Três coisas que estavam como não-metas da v1 viram a Fase 3, pedidas pelo usuário em 2026-10-24. As três giram em torno de um mesmo incômodo: **não perder o fio do trabalho com vários agentes**.

1. **Registro de trabalho + chat de status** (o que o Maestri chamava de "chat por terminal", repensado). O problema real, nas palavras do usuário: o terminal do Claude Code "se perde no que está fazendo"; a lista de tarefas dele "fica desatualizada, com tarefas anteriores, e nunca mais é limpa", e o usuário "tem que fechar o terminal e abrir de novo" para voltar a usá-lo direito; também perde de vista os subagentes e shells que estão rodando. O que ele quer **[usuário]**: algo que faça esse controle, garanta que funcione, e deixe claro "o status e onde estamos", sem ter de lembrar qual terminal faz o quê. Também é o canal para mandar pedidos aos agentes.
2. **Partituras**: modelos reutilizáveis de equipe no canvas. O usuário ainda não tem um arranjo que repete, mas acha "um ótimo investimento" que "agilizaria muito" **[usuário]**.
3. **Assistente local**: um resumo, por trabalho, do que **foi feito**, do que **ficou para depois** e do que **não foi feito** **[usuário]**, sem gastar o plano dos agentes.

## 2. Metas, não-metas, anti-metas

### Metas
- **Registro de trabalho** mantido pelo daemon, alimentado pelos agentes (hooks), que **sobrevive a compactação e reinício** e **é limpo** quando o trabalho acaba.
- **Chat de status** no app (Mac): perguntar "onde estamos", ver tarefas/subagentes/shells vivos, mandar pedidos aos agentes, e **devolver ao agente só o que está vivo** (sem reiniciar o terminal).
- **Partituras**: prontas de fábrica, salvar a partir do canvas, aplicar, compartilhar por arquivo; **o Maestro também cria, salva e aplica** **[usuário]**.
- **Resumo por trabalho** (feito / para depois / não feito), sempre disponível; reescrito e com perguntas livres pelo modelo local quando houver.

### Não-metas (desta fase)
- **Celular / acesso remoto** — fica para depois **[usuário]**. Quando vier, precisa **mandar pedidos e aprovar**, não só acompanhar **[usuário]**. Nada nesta fase pode impedir isso depois (o chat fala com o daemon pelo mesmo protocolo que um cliente remoto usaria).
- Terminais SSH/Docker/sandbox, iPhone físico, plug-ins de terceiros, multiusuário, Windows/Linux, licenciamento (continuam fora).
- Substituir a lista de tarefas interna do Claude Code: o Orq a **acompanha e corrige o contexto**, não a reimplementa dentro do agente.

### Anti-metas (fracasso mesmo que "funcione")
- **Partituras ou resumos falhando com frequência** **[usuário]**. Concretamente: partitura aplicada pela metade (alguns terminais criados, cordas faltando), resumo que não sai ou sai errado.
- Registro que **cresce sem limpar** — repetir o problema que motivou a fase.
- O registro **inventar** estado (tarefa "feita" que não foi, subagente "vivo" que morreu).
- Qualquer coisa disto gastando tokens do plano do usuário sem ele pedir.
- As anti-metas da v1 continuam: RAM crescendo, trabalho pesado na main thread, chamadas que travam.

## 3. Restrições

- Tudo da v1 continua: Swift/macOS nativo, macOS mínimo **15**; **corda é a única permissão** entre terminais, Maestro incluído; segredos (token de admin, links do figcraft) nunca chegam a agentes; **nada sai da máquina** sem pedido explícito do usuário; nada é apagado sem o usuário (arquivar ≠ apagar); clean-room em relação ao Maestri; protocolo `v: 1`.
- Hooks dos agentes já são ligados **por terminal, por flag, sem tocar em configuração global** (`AgentLaunch.launchSpec` grava `<hooksDir>/<id>.claude.json` com `Stop`, `SessionStart`, `UserPromptSubmit`) — a Fase 3 estende esse mesmo arquivo.
- **Modelo local**: Apple **FoundationModels** só existe no **macOS 26** com Apple Intelligence ligado. O Orq continua rodando no macOS 15. **[call]** O resumo existe sempre (montado dos dados do registro, sem IA); o modelo local, quando disponível, reescreve em linguagem natural e responde perguntas livres. Sem ele, a pergunta livre diz que precisa do macOS 26 + Apple Intelligence.
- Nada de rede para o assistente: só o modelo on-device.

## 4. Registro de trabalho

### 4.1 O que é um "trabalho"
Uma unidade de trabalho com começo e fim — um plano, uma feature, um bug — ligada a **um terminal principal** (normalmente o Maestro) e aos terminais que ele recrutou/está ligado por corda. **[call]** O trabalho nasce: (a) quando um agente declara (`orq work start "<título>"`), (b) quando o usuário cria pelo chat, ou (c) implicitamente na primeira tarefa registrada por um terminal sem trabalho aberto (título provisório editável). Um terminal tem no máximo um trabalho ativo.

### 4.2 O que entra
Alimentado por hooks do Claude Code no arquivo de hooks do terminal (sem configuração global). **[call]** Eventos usados:
- criação/atualização/fechamento de **tarefas** do agente (as ferramentas de lista de tarefas/todos do Claude Code, via `PostToolUse` filtrado por ferramenta);
- **subagentes** iniciados e terminados (lançamento da ferramenta de subagente + `SubagentStop`);
- **shells em segundo plano** iniciados e terminados (comando com execução em background);
- fim de turno (`Stop`), início de sessão (`SessionStart`), compactação (`PreCompact`, se disponível).
- Commits/merges do repositório do terminal (o daemon já roda git para andares) para "feito".
- Comandos explícitos para quem não tem hooks (Codex, shell genérico): `orq work task add|done|defer|drop`, `orq work note`. **[call]** Codex só tem o caminho explícito nesta fase.
O builder confirma, na versão do Claude Code instalada, os nomes exatos dos eventos e o formato do payload; o que não houver por hook fica pelo comando explícito.

### 4.3 Estados
Tarefa: `aberta`, `em andamento`, `feita`, `para depois` (com motivo), `abandonada` (com motivo). Subagente/shell: cada um é uma entidade própria com id (o id da chamada de ferramenta que o criou, vindo no hook), ligada ao terminal que o criou. Estados: `rodando`, `terminou` (código/resultado curto), `sumiu` e `desconhecido`. **[call]** `sumiu` só quando o daemon **confirma** que acabou sem evento de fim (shell em segundo plano com PID conferível que não existe mais; ou o terminal/processo do agente morreu). Subagentes do Claude Code rodam dentro do processo do agente, sem PID próprio: sem evento de fim, viram `desconhecido` depois de um tempo sem sinal — nunca `sumiu`.
- Lista de tarefas do Claude Code: a ferramenta reescreve a lista inteira a cada chamada; o daemon **compara com a anterior** para achar o que entrou, mudou ou saiu. **[call]** Os estados `para depois` e `abandonada` (com motivo) só existem pelos comandos explícitos (`orq work task defer|drop "<motivo>"`); uma tarefa que some da lista do agente sem ter sido feita fica `abandonada` sem motivo. As instruções que o Orq já dá aos agentes (skills/hooks da v1) passam a pedir que usem `defer`/`drop` ao adiar ou desistir.

### 4.4 Fechar e limpar
Um trabalho fecha por **qualquer um dos três** **[usuário]**: o **merge** do branch/andar do trabalho (detectado pelo daemon), o **agente** (`orq work done`), ou o **usuário** (no chat). **[call]** Fechar por merge só vale para trabalho com **branch próprio** (o do andar, ou um branch criado/declarado pelo trabalho: `orq work start --branch <b>`): quando esse branch entra no branch de destino, fecha. Trabalho no térreo sem branch próprio nunca fecha sozinho — só agente ou usuário. Fechar é reversível ("reabrir" volta as tarefas para a lista ativa). Ao fechar, as tarefas saem da lista ativa e vão para o **histórico** do trabalho (nada é apagado; o usuário pode apagar do histórico). Tarefas ainda abertas no fechamento viram "não feito" no resumo.

### 4.5 Devolver o contexto limpo ao agente
O chat oferece **"Recolocar no trilho"** para um terminal: o Orq injeta no agente (pelo mesmo injetor de prompts da v1) um bloco curto com **só o estado vivo** do trabalho atual — tarefas abertas/em andamento, subagentes/shells rodando, decisões recentes — e a instrução de considerar o resto encerrado. **[call]** Injeção só por ação do usuário (ou do Maestro, para os terminais ligados a ele), nunca automática.

### 4.6 Quem pode o quê
**[call]** Mesmas regras de corda da v1: um terminal mexe no **próprio** trabalho (`work start|done|task|note`); um Maestro mexe também nos trabalhos dos terminais que alcança por corda; o app (admin) mexe em tudo. Ninguém lê ou altera trabalho de terminal fora do seu alcance.

### 4.7 Onde vive
No daemon, persistido por workspace (mesma pasta de dados do Orq), com limites de tamanho e retenção do histórico (o builder fixa os números; o histórico não se apaga sozinho, mas o usuário tem "limpar histórico"). Eventos de hook chegam pelo socket como os hooks atuais.

## 5. Chat de status (app do Mac)

- Um painel de doca **"Trabalho"** (plug-in de primeira parte, mesmo modelo da §6 da v1). **[call]** Um painel por workspace, não por terminal — responde "não ter de lembrar qual terminal faz o quê".
- Mostra: trabalhos ativos (por terminal/andar), cada um com tarefas por estado, subagentes e shells vivos (com alerta para `sumiu`/`desconhecido`), e o resumo (§7).
- Conversa: o usuário escreve; **[call]** mensagens começando por `@<terminal>` vão para aquele agente (pelo mesmo caminho do `ask` da v1, respeitando que o app é admin); sem `@`, vão para o **Maestro do trabalho selecionado** (que delega pelas cordas), ou, se o trabalho não tem Maestro, para o seu **terminal principal**. Perguntas de status são respondidas **pelo registro**, sem gastar tokens: no macOS 15, um conjunto fixo de perguntas reconhecidas por palavras-chave e botões ("onde estamos", "o que travou", "o que está rodando", "resumo"); no macOS 26 com modelo local, perguntas livres. Texto que não é pergunta de status reconhecida vai para o agente, como mensagem normal.
- **Aprovações**: quando um agente para pedindo permissão (o detector de atenção da v1 já percebe), o pedido aparece no chat com aprovar/negar, que responde no terminal. **[call]** Antes de enviar a resposta, o daemon confere que **o mesmo pedido** ainda está na tela do terminal (texto do prompt igual ao capturado); se mudou ou sumiu, não envia nada e avisa "pedido não está mais pendente". Isso prepara o celular (mesma ação remota depois).
- Histórico do chat persistido por workspace.

## 6. Partituras

### 6.1 O que guarda
Terminais (agente/preset, nome, papel/prompt inicial, se é Maestro, posição), **cordas** entre eles, **painéis** (plug-in, posição, estado não secreto — ex.: arquivo de design por nome, URL do navegador), e se **pede andar**. **Nunca**: histórico de terminal, tokens, links do figcraft, variáveis de ambiente com segredo, caminhos absolutos do usuário (o repositório é "o do workspace onde se aplica").

### 6.2 Fontes
- **Prontas de fábrica** **[call]**: "Feature fullstack" (Maestro + dev backend + dev UI com Design/Navegador + revisor; pede andar) e "Investigar bug" (Maestro + investigador + quem escreve o teste; sem andar). Textos de papel originais.
- **Salvar do canvas**: selecionar terminais/painéis → "Salvar como partitura".
- **O Maestro salva e aplica** **[usuário]**: comandos de agente (`orq partitura save|apply|list`) dentro das regras de corda — o Maestro só salva o que alcança, e o que ele aplica nasce ligado a ele.
- **Arquivo**: exportar/importar um arquivo de partitura (formato próprio, versionado, clean-room). Na importação, mostrar tudo que será criado e **quais comandos/prompts serão executados** antes de confirmar.

### 6.3 Aplicar
Usuário escolhe partitura + nome (ex.: "feature X"); **[call]** cada partitura diz se pede andar (a fullstack pede; a de bug não) e o usuário pode inverter na hora. **Tudo ou nada** (anti-meta): o Orq cria tudo e, se qualquer parte falhar (agente não sobe, andar não cria, painel recusa), **desfaz o que criou** e mostra o motivo. **[call]** "Agente subiu" = o processo do terminal está vivo e o agente chegou ao primeiro prompt (o mesmo sinal de "pronto" que o `recruit` da v1 usa) dentro de um prazo; o desfazer só remove o que **esta aplicação** acabou de criar e ainda não tem trabalho do usuário (terminais recém-criados, andar e branch recém-criados sem commits) — exceção explícita e estreita ao "nada é apagado sem o usuário".
- **Quem pode aplicar** **[call]**: o app; um Maestro, que já pode recrutar e criar andares pelas regras da v1 — a partitura não dá poder novo: o que ela cria nasce ligado por corda ao Maestro que aplicou, e andares seguem as regras de criação de andar da v1. O resultado aparece onde o usuário clicou (ou ao lado do Maestro que aplicou).

## 7. Resumo do trabalho (assistente)

- Para cada trabalho (ativo ou fechado): **Feito** (tarefas feitas, commits, merges), **Para depois** (tarefas adiadas com motivo; decisões que um agente tomou pelo usuário, quando registradas com `orq work note --decision`), **Não feito** (tarefas abertas/abandonadas no fechamento, subagentes/shells que sumiram, onde parou).
- **Sempre** disponível, montado direto do registro (determinístico, instantâneo, sem tokens) — atende a anti-meta "resumo falhando".
- **Com modelo local** (macOS 26 + Apple Intelligence): reescreve o resumo em linguagem natural e responde perguntas livres no chat, usando **só** dados do registro/workspace como ferramentas (sem rede). Se o modelo falhar ou demorar, mostra o resumo determinístico.
- O resumo também vai para a Memória da v1 ao fechar um trabalho **[call]** (como entrada `map`/`decision` do repositório, revisável), para alimentar sessões futuras.

## 8. Protocolo
**[call]** Tudo novo entra como mensagens **adicionais** do `v: 1` (comandos e eventos novos que clientes antigos ignoram), como a v1 já fez a cada plano. Nenhuma quebra.

## 9. Ordem sugerida

**[call]** 3A Registro de trabalho (daemon + hooks + comandos) → 3B Painel Trabalho + chat + aprovações + "Recolocar no trilho" → 3C Resumo (determinístico + modelo local) → 3D Partituras. O registro vem primeiro porque o chat e o resumo dependem dele; partituras são independentes e podem andar em paralelo se preferir.

## 10. Deixado para o builder

Nomes exatos dos eventos/payloads de hook na versão instalada do Claude Code; formato do arquivo de partitura; limites de tamanho/retenção; heurística de "sumiu/desconhecido"; layout do painel; textos dos papéis das partituras de fábrica; como mapear um merge a um trabalho (branch/andar do terminal principal).
