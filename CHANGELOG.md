# Changelog

Todas as mudanças notáveis do Collie, por versão. O formato segue o [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e as versões seguem as tags `v*` do repositório (cada tag publica um release assinado e notarizado).

## [Não lançado]

### Corrigido
- **CI determinístico:** o passo de testes (`scripts/ci/run-tests.sh`) não confia mais no código de saída do `swift test`, que deu verde com 237 falhas quando o processo de teste saiu no meio; roda a suíte em 3 partes seriais e só passa com a contagem final de cada uma. Testes que o runner hospedado não roda ficam em `scripts/ci/ci-skip.txt`, com o motivo. Testes desatualizados (`--plugin-dir` do Cursor, título da página no import) e uma falha fatal do falso daemon do `MCPTests` corrigidos.

## [0.1.7] — 2026-11-19

### Adicionado
- **Layout "Trilho"** na estrutura Completa: coluna de cercados à esquerda, painel de contexto com a **árvore de agentes** (o Pastor e os terminais ligados a ele por guia, com selo de cartões pendentes) e faixa de abas Canvas / Preferências. Na Completa, as Preferências passam a abrir **no lugar do canvas** (`⌘,`, paleta, engrenagem e o pedido de página de outros painéis), sem refazer os terminais. A estrutura Compacta não muda e continua abrindo a janela de Ajustes.
- **Memória de conversa do Cursor:** o início de sessão de um terminal Cursor é registrado, a transcrição é lida em blocos e o crescimento dela dispara a captura por ociosidade.
- **Curador:** sem limite diário por padrão (o limite passa a ser uma escolha do usuário).

### Alterado
- No Trilho, o **Pasto** (terminais e painéis sem cercado) não é mais um cercado fixo: só aparece enquanto tiver algo, quando é a seleção ou quando não há cercado; vazio e selecionado, o app passa para o primeiro cercado. A Compacta mantém o chip "Pasto".
- O baseline do lint para `sleep` em `ConversationCapture.swift` subiu de 1 para 2: é o poll do crescimento da transcrição do Cursor, que não tem evento para esperar.

### Corrigido
- Curador: o perfil de sandbox do Claude deixa o `dyld` iniciar, mantém o diretório temporário dentro do perfil e deixa ler o link com que foi iniciado; o Claude sempre recebe `USER`, mesmo quando a captura do ambiente falha.
- Memória: uma transcrição do Cursor que aparece depois do `sessionStart` é encontrada na captura.

## [0.1.6] — 2026-11-19

### Adicionado
- **Laços sem cartão por cercado:** o cartão do laço ganha "Sempre neste cercado"; depois disso os laços daquele cercado começam sem cartão e o Pastor recebe só um aviso. Nova página **Laços** nas Preferências, com **Revogar**.
- **Laço mais confiável:** `collie work run --gate "<cmd>"` roda um portão (lint, build) depois do check de cada tarefa; o laço falha a tentativa que reescreve um script que o portão executa (salvo o que o spec da tarefa cita); registra e mostra a **evidência** de cada tarefa aprovada; espera outro terminal do mesmo worktree em vez de parar; avisa o Pastor ao fim de cada tarefa; mostra no status o que está fazendo (agente, check ou portão) e os números do laço (tentativas, commits revertidos).
- **Memória que vira regra:** uma armadilha ou decisão pode ser imposta por um check (`enforcedBy`, `memory enforce`); armadilhas recorrentes sem check aparecem como candidatas; item imposto sai da injeção, do TTL e da contagem de mortas; se o check some, a memória volta à injeção.
- **Mapa de funcionalidades** (`docs/feature-map.md`) e a regra de lint `feature-map`.
- **CI:** `ci.yml` (lint, arquitetura, build e testes em PRs e na `main`), `check-architecture.sh` (fronteiras entre módulos; módulos-base não importam Cocoa, Carbon, Quartz, PDFKit nem SwiftUI) e um lint de catraca para `sleep`, escapes de concorrência e casts forçados.

### Corrigido
- O laço não espera mais o Pastor ficar ocioso para seguir.
- `collied` não cai mais quando o terminal some durante `noteModel`.
- Memória: um check que sumiu não grava marca de "desatualizada"; só armadilhas verificadas viram candidatas.
- O pacote declara `CollieCore` como dependência direta de `collie` e `collied`.

## [0.1.5] — 2026-11-18

### Adicionado
- **Curador com provedor à escolha:** novo provedor **Cursor** (isolado e sem ferramentas); em Preferências › Memória o usuário escolhe o provedor, dá o consentimento e testa.

### Corrigido
- Curador: valida o id do modelo; o Cursor sempre roda com sandbox em produção; nunca segue um link plantado na home do Cursor; o perfil do Cursor executa as ferramentas reais e só a porta 443; distingue ambiente do usuário não capturado de `claude` ausente e procura o `claude` em diretórios conhecidos quando o ambiente não tem `PATH`.

## [0.1.4] — 2026-11-18

### Adicionado
- **Laços sem supervisão:** `collie work run` / `work stop`, motor do laço (agente novo por tentativa, o check de cada tarefa decide), spec e check por tarefa, cartão de aprovação no app com limites rígidos, `/collie:loop` para terminais Claude e Cursor, e o estado do laço com ação de parar no painel Trabalho.
- **Medição da memória:** métrica de precisão ao lado da cobertura, uso com evidência (citação do turno, `memory.get`, `--useful`), estatísticas por agente e obediência a `ask`, TTL provisório por tipo e índice de início de sessão por uso, com teto para memórias fixadas.
- **Memória para Cursor e Codex:** `memory.task` (puxada por tarefa, para agentes sem hook de prompt), `sessionStart` focado e limitado para o Cursor, perfil do MCP e selo de memória nos cartões do Cursor, com preferência e **Confiar** em Preferências › Memória.
- **Deriva de mapa:** memórias de mapa cujo arquivo mudou desde a âncora são contestadas, e o curador recebe o fato verificado.
- **Curador:** provedores atrás de uma interface única, perfil de sandbox próprio (nega por padrão), pausa por saída ruim, resultados de job, e um livro de proveniência fora dos arquivos de memória; registros trazem quem os curou.
- **Rede:** o pacote de confiança do macOS vai para o `mitmdump` em toda partida e a CA de upstream respeita a configuração do mitmproxy do usuário.

### Segurança
- O laço nunca roda check nem `git` sem sandbox, nunca desfaz trabalho alheio nem sobrevive aos seus agentes, esconde segredos nas notas, e o cartão de aprovação mostra todas as tarefas de forma inforjável; um laço por cercado mesmo sob `work run` concorrente.
- Memória injetada é rotulada como dado, escapada e limpa; só memória escrita pelo daemon entra por inteiro ou como regra do usuário; veredictos do curador falham fechado; um ledger de proveniência corrompido não adota nada.
- O `git` do daemon não usa busca preguiçosa nem o transporte `ext`.

### Corrigido
- Um filho que expira e morre no SIGTERM não trava mais; `adb root` recusado nomeia a causa; leituras de arquivo de mapa interrompidas por sinal são repetidas; âncoras de mapa por loja, sem vaivém entre Pasto e worktree.

## [0.1.3] — 2026-11-17

### Alterado
- A detecção de "não é admin" virou um aviso único, não uma etiqueta vermelha; a etiqueta de detecção diz o motivo e como corrigir, e o vigia do sandbox explica por que a detecção está desligada.

## [0.1.2] — 2026-11-17

### Adicionado
- **Atualizador automático:** o daemon confere o manifesto de releases, prepara o dmg, e o app troca o bundle de forma verificada, guarda o anterior e reabre. Nova página **Atualizações** e folha de instalação; comandos `app.update` (admin).
- O sandbox nega escritas ao irmão de atualização; download com limite de bytes e caminhos de release do Collie.
- O Pastor delega com `collie summon`, não com subagentes próprios.
- Comandos que um daemon antigo não conhece respondem "reinicie o serviço para usar isto".

## [0.1.1] — 2026-11-16

### Adicionado
- **Motor do Design (figcraft) como plug-in baixável:** o app e o daemon baixam, verificam e instalam o motor (pin e resolução de versão), com comandos `design.engine` (admin) e CLI; o painel Design oferece o download; Preferências abre na página que o painel pede.
- Release: notarização por chave de API, espera com polling e versão forçada.

### Corrigido
- CI: tolera "already exists" ao importar o keychain e exige a identidade de assinatura.

## [0.1.0] — 2026-11-16

Primeira versão pública (antes o projeto se chamava Orq).

### Adicionado
- **Canvas** com terminais de agentes (Claude, Codex, Cursor), guias entre eles e **cercados** (worktrees git ou pastas); tela cheia por janela.
- **Painéis:** Navegador (dirigido pelo agente), Dispositivo (Android via adb/scrcpy, Simulador iOS via AXe), Design, Design Systems, Diagrama (draw.io), Prévia de páginas HTML com comentários, Artifacts, Rede (mapeamento local de respostas) e Trabalho.
- **Memória** em três escopos (global, projeto e lote), injetada no prompt dos agentes.
- **Rebanhos** (equipes prontas de terminais e painéis) e **Lotes** (agrupamento de terminais por esforço).
- **Sandbox** (Seatbelt) em todo terminal, modo aberto (padrão) ou estrito, com cartões de acesso.
- **Comunicação entre agentes:** `collie ask`/`reply` com remetente verificado, `summon`, `wait`.
- **Apps do cercado** com aprovação e eventos.
- **Preferências** com barra lateral e busca (Aparência, Terminal e fontes, Desenho e sandbox, Memória, Plug-ins, Celular, Android).
- Release assinado com Developer ID e notarizado (dmg).
