# Orquestrador modular de agentes (versão própria do Maestri) — Design

> Status: rascunho para aprovação · Data: 2026-10-18
> Base de referência: a análise de referência (local, não publicada) (engenharia reversa read-only do Maestri 0.49.4).
> Reconstrução **clean-room**: reaproveita ideias de arquitetura/comportamento; nunca copia código, ícones, textos ou marca do Maestri.
> Convenção: itens marcados **[call]** são decisões do designer (Claude), não do usuário — revisar.

---

## 1. Intenção e porquê

Um app macOS para o próprio usuário orquestrar vários agentes de código (Claude Code, Codex, …) num **canvas infinito**, com a mesma cara do Maestri, mas construído como **base + plug-ins**.

Dores que motivam:
1. **Artifacts espalhados.** Uma landing page recente ficou dividida entre HTML e Figma, sem fonte única. O usuário quer um **sistema de design centralizado**: o canvas de design é a fonte da verdade e o HTML sai dele.
2. **Agentes não usam a memória.** Ao pedir algo já trabalhado, o agente relê o código em vez de consultar a memória. A memória precisa ser **empurrada** para o agente, não depender de ele buscar.
3. **Fragilidade do Maestri** (anti-meta explícita): leaks de memória, lentidão, quebras repentinas em chamadas de ferramentas.

Sucesso = o usuário consegue, do terminal Maestro, mandar agentes criarem/alterarem telas num design único com design system trocável, ver os artifacts num painel, e os agentes chegam já sabendo as decisões e onde fica cada coisa — sem o app ficar pesado ou instável.

---

## 2. Metas, não-metas, anti-metas

### Metas (v1)
- **Núcleo herdado do Maestri:** canvas infinito; terminais com agentes; conexões por corda (corda = permissão de conversar); terminal **Maestro** com comandos privilegiados; **andares** (floors: isolamento via git worktree, "land" de volta); **painel de uso dos agentes** (consumo de plano por CLI de agente, janelas 5h/7d — confirmado pelo usuário).
- **Sistema de plug-ins** com painéis em posição **híbrida** (doca OU nó no canvas), comandos para agentes e eventos.
- **Plug-ins de primeira parte:** Design (figcraft), Design Systems, Artifacts, Navegador, Memória, **Dispositivos** (Android via scrcpy + Simulador iOS — adicionado pelo usuário em 2026-10-18; ver §7.6).
- **Memória própria** em Swift com injeção ativa, mapa do projeto, revisão e limpeza reversível.

### Não-metas (v1 — ficam para depois) [call, derivado da lista do usuário]
Rotinas agendadas · chat por terminal · partituras · app iOS / acesso remoto (Wire) · terminais SSH/Docker/sandbox · assistente de IA local (Ombro) · iPhone físico · notas soltas no canvas (Memória cobre) · plug-ins de terceiros instaláveis · colaboração multiusuário · Windows/Linux · licenciamento/monetização.

### Anti-metas (fracasso mesmo que "funcione")
- Uso de RAM crescendo sem limite (leaks, scrollback infinito em memória, webviews/processos órfãos).
- Lentidão: canvas travando com muitos terminais; trabalho pesado na main thread.
- Chamadas de ferramenta que quebram/travam/voltam cortadas (o ponto fraco do `maestri ask` por raspagem de tela).

---

## 3. Restrições

- **Plataforma: Swift, macOS nativo** (decisão do usuário). SwiftUI + AppKit, como o Maestri. macOS mínimo: **[call] 15.x** (mesmo patamar do Maestri; só sobe se uma API exigir).
- Distribuição pessoal: Developer ID + hardened runtime, **sem App Sandbox** (precisa PTY, git, processos auxiliares). Sem loja.
- **figcraft** (Rust, MIT OR Apache-2.0, alpha, API muda rápido) e qualquer componente Rust integram como **processos auxiliares**, não como biblioteca linkada — o usuário quer manter Swift e "uma maneira de eles se comunicarem". Remover marcas ArtCraft de qualquer build do figcraft distribuído.
- **ai-memory** (MIT) é **referência de ideias**, não dependência: a memória é escrita do zero em Swift (decisão do usuário).
- Clean-room em relação ao Maestri.
- **Convive com o Maestri** instalado e rodando **[call]**: nomes próprios para CLI, socket, variáveis de ambiente, skills e hooks (nada com prefixo `maestri`); sem importar dados de `~/.maestri`.
- Nome do app/CLI ainda não definido; este documento usa `<app>` **[call: usuário escolhe]**.

### Ordem de entrega (decisão do usuário: núcleo primeiro)
1. **Fase 1 — Núcleo + Memória:** canvas, terminais, cordas, Maestro, comunicação entre agentes via daemon, andares, painel de uso, sistema de plug-ins (com Memória como primeiro plug-in de doca) e Navegador **[call: Navegador entra na fase 1 por não depender do motor de design]**. Utilizável no dia a dia ao fim desta fase.
2. **Fase 2 — Design:** spike do figcraft (§7.1) no início da fase; depois Design, Design Systems, Artifacts e importação de HTML.
O motor de design fica atrás de um **adaptador nosso** (`DesignEngine`), para poder ser trocado.

---

## 4. Arquitetura geral

```
┌─────────────────────────── App (UI, SwiftUI+AppKit) ───────────────────────────┐
│ Canvas (viewport AppKit, nós SwiftUI) │ Docas (esq/dir/baixo) │ Plugin Host    │
│ Painéis: Design · DesignSystems · Artifacts · Navegador · Memória · Uso         │
└───────────────▲─────────────────────────────────────────────▲─────────────────┘
                │ IPC local (versionado)                       │ eventos
┌───────────────┴──────────── Daemon (processo separado) ─────┴─────────────────┐
│ PTYs/terminais + tmux-like persistência │ Servidor de comandos (CLI + MCP)      │
│ Captura estruturada de respostas (hooks) │ Memória (store+índice+limpeza)        │
│ Supervisor de processos auxiliares (figcraft, headless browser p/ import HTML) │
└────────────────────────────────────────────────────────────────────────────────┘
          ▲ CLI `<app>` / MCP                 ▲ hooks (Claude Code, Codex)
   Agentes nos terminais ───────────────────────┘
```

Decisões:
- **App e daemon separados** (decisão acordada com o usuário para a anti-meta de quebras): terminais e servidor de comandos vivem num daemon; se a UI travar/cair, agentes continuam e a UI reconecta. **[call]** Daemon é um executável Swift no bundle, lançado como LaunchAgent do usuário ou filho supervisionado; o builder escolhe.
- **Uma única superfície de comandos para agentes**, exposta por **CLI** (como o `maestri`) **e** por **MCP** (agentes já falam MCP). Mesmas operações, mesmo schema.
- **Protocolo versionado e estruturado** (JSON com schema e versão, erros tipados com código e mensagem, timeouts explícitos por comando). Diferente do Maestri (texto puro, sem versão).
- **Autenticação local forte** (corrige fraqueza do Maestri): cada terminal recebe um token secreto (não só um UUID) além do socket com permissão restrita; o daemon valida token **[call]** e, quando possível, a ancestralidade do processo chamador.

---

## 5. Núcleo (herdado do Maestri)

Comportamento de referência detalhado em a análise de referência (local, não publicada) §3. Resumo do que a v1 precisa:

- **Canvas:** pan/zoom, minimap, seleção, mover/redimensionar, tidy/align, grupos, foco (expandir nó). Nós: terminal, painel de plug-in.
- **Cordas:** conexões tipadas entre nós; definem quem fala com quem. Visual de corda (física) é desejável, não obrigatório **[call]**.
- **Terminais:** PTY por terminal, temas/fonte, busca, histórico. Presets de agente (comando + tipo: claude_code, codex, shell, custom). Badges trabalhando / precisa de atenção.
- **Maestro:** um terminal marcado como Maestro tem comandos privilegiados (recrutar/dispensar agentes, conectar, criar/land de andar, abrir painéis em qualquer lugar). **Alcance do Maestro = só terminais ligados a ele por corda** (decisão do usuário 2026-10-19: alcance amplo afetaria agentes em trabalho paralelo fora do escopo). Recrutar cria a corda automaticamente; vários Maestros ficam isolados salvo corda explícita.
- **Comunicação entre agentes** (`ask`, `check`, `list`, `notify`…): mesma semântica do Maestri (só entre nós conectados; deadlock detectado), mas **resposta via eventos estruturados** (ver §8).
- **Andares (floors):** canvas isolado + cópia do repo via git worktree (APFS clone quando possível); status (trabalhando/bloqueado/revisão/feito); land = merge/squash/rebase ou PR. Cada andar pode ter **design system próprio** (§6.2).
- **Uso dos agentes:** painel com consumo de plano por agente (janelas 5h / 7d etc.), via provedores declarativos que consultam as CLIs — como o Maestri.
- **Persistência do núcleo:** JSON Codable por workspace (como o Maestri), com versão de schema e migrações **[call]**.

---

## 6. Sistema de plug-ins

### 6.1 Modelo
Plug-in = pacote de primeira parte (compilado no app na v1) que declara:
1. **Painéis**, cada um com posições permitidas: `dock.left | dock.right | dock.bottom | canvas` (decisão do usuário: **híbrido**). Um painel pode ser movido entre doca e canvas pelo usuário.
2. **Comandos para agentes** (nome, parâmetros com schema, resultado com schema, permissão exigida). Expostos automaticamente via CLI e MCP.
3. **Eventos** que emite (ex.: `artifact.exported`, `memory.superseded`, `designsystem.changed`, `browser.loaded`), entregues a agentes conectados e a outros plug-ins.

### 6.2 Regras de acesso
- Painel **no canvas**: só agentes ligados por corda a ele podem chamar seus comandos (regra do Maestri).
- Painel **na doca**: global ao workspace — qualquer agente do workspace pode usar. **[call]** Possível restringir por plug-in no futuro.
- **Agentes podem abrir painéis** (normalmente o Maestro): "abrir X na doca direita" ou "soltar Y no canvas ligado a mim". Acontece direto, sem confirmação (abrir painel não destrói nada). **[call]**

### 6.3 Ciclo de vida e recursos (anti-metas)
- Painel fechado libera tudo (webview, processos, caches).
- Processos auxiliares de plug-ins são supervisionados pelo daemon: iniciados sob demanda, encerrados ociosos, reiniciados ao cair, com limite de memória.
- Cada plug-in reporta uso de RAM; medidor visível ao usuário.

### 6.4 Plug-ins de terceiros
Fora da v1. O modelo de §6.1 deve ser o mesmo que um plug-in externo usaria depois (não criar atalhos internos que impeçam isso), mas sem empacotamento/instalação/sandbox na v1.

---

## 7. Plug-ins de primeira parte

### 7.1 Design (figcraft) — fonte da verdade
- **Papel:** onde as telas "moram". HTML é sempre **exportação** do design.
- **Integração** (figcraft é Rust, alpha): processo auxiliar. Visualização no app via **build web (WASM) do figcraft em WKWebView**, e agentes editando o **mesmo documento ao vivo**.
- **Risco #1 (spike obrigatório antes do plano detalhado):** o MCP do figcraft em modo headless edita uma cópia própria do documento; o modo "attached" exige o app desktop dele com canal de controle TCP. Precisamos de **uma fonte única** que a UI mostra e os agentes editam. Caminhos a avaliar no spike: (a) sessão colaborativa via `figcraft-server` com a UI WASM e um cliente de agente juntos; (b) app desktop do figcraft como janela separada + `--control`, agentes via MCP attached; (c) nosso processo Rust fino sobre `figcraft-engine` expondo controle + sessão colaborativa. Escolha fica para o builder com base no spike.
- **Se nenhum caminho der fonte única ao vivo: trocar de motor de design** (decisão do usuário) — não aceitar cópias sincronizadas nem HTML como fonte. O adaptador `DesignEngine` define o contrato que qualquer motor precisa cumprir (documento único editável por UI e agentes, variáveis/componentes, auto layout, export HTML/CSS); o spike avalia figcraft contra esse contrato e, se falhar, o builder pesquisa alternativa e volta ao usuário com a recomendação antes de seguir a fase 2.
- **Versão:** fixar figcraft na release **v0.7.0** (repo `storytold/figcraft`, sem checkout local) **[call]**; atualizar só deliberadamente.
- **Importar do Figma: fora de escopo** **[call]** — só HTML entra.
- **Comandos para agentes:** criar/editar telas e frames (repassando os comandos do figcraft), screenshot, exportar HTML/CSS, importar HTML (§7.1.1).
- **Exportação HTML:** usa o codegen existente do figcraft (auto layout → flexbox, variáveis → CSS custom properties). Lacunas conhecidas a fechar: só `<div>/<p>`, imagens como placeholder, vetores não inlinados, sem grid. HTML exportado usa o CSS do **design system ativo**.

#### 7.1.1 Importar HTML como nova tela (decisão do usuário)
Todo HTML gerado por agente fora do design é **importado como nova tela** — o design continua fonte única.
- figcraft **não importa HTML hoje**. Abordagem **[call]**: renderizar o HTML num WKWebView invisível, ler caixas e estilos computados do DOM, mapear flex → auto layout, texto → text nodes, imagens/SVG → fills/vetores, e criar os frames via comandos do figcraft em lote (um passo de desfazer).
- Resultado é **aproximado**; aceitável. Risco #2 a validar cedo usando uma landing page real como caso de teste (o usuário fornece os arquivos no início da fase 2).
- **Após importar, a tela do design é a oficial** **[call, derivado de "design é fonte da verdade"]**. O HTML original fica arquivado como "origem" do artifact (somente leitura). O artifact passa a ser o export dessa tela; "desatualizado" compara o último export com o estado atual do design. Edições posteriores do agente passam pelo design, não pelo HTML original.

### 7.2 Design Systems
- Design system = arquivo do figcraft contendo variáveis (cor, tipografia, espaçamento, com modos tipo claro/escuro), estilos e componentes. Vive numa **biblioteca de design systems**.
- **Workspace** tem um design system ativo; **andar** herda ou define outro (permite testar visual num andar sem afetar o principal).
- Telas referenciam variáveis/componentes do sistema ativo → **trocar o sistema reestiliza as telas**; HTML exportado sai com o CSS do sistema ativo.
- Comandos para agentes: listar, trocar ativo, criar a partir de outro, atualizar tokens/componentes.
- **Mudanças aplicam na hora, com desfazer** (decisão do usuário). Histórico de versões do design system para voltar atrás.
- Toda troca/atualização gera uma **decisão na Memória** com o motivo **[call]**.

### 7.3 Artifacts (painel, tipicamente doca)
- Lista: **telas exportadas do design** e **HTMLs gerados por agentes** (decisão do usuário).
- Cada item: miniatura, tela de origem no design, quem gerou, quando, e **se está desatualizado** em relação ao design.
- Ações: abrir no Design, abrir no Navegador, reexportar.
- HTML gerado por agente entra pelo **comando de artifact** (agente registra explicitamente) **[call]** — não varredura do disco — e dispara a importação §7.1.1.

### 7.4 Navegador (painel, tipicamente nó no canvas)
- WKWebView controlável por agentes ligados por corda: navegar, snapshot com referências de elementos, clicar, preencher, digitar, rolar, avaliar JS, screenshot, logs do console, redimensionar (paridade funcional com o portal do Maestri).
- Pré-visualização de artifacts.
- Armazenamento por portal (isolado / workspace / global) e **limpeza dos dados ao deletar** (Maestri vaza isso).
- Sem simuladores mobile na v1.

### 7.5 Memória (painel, tipicamente doca)
Ver §8.

### 7.6 Dispositivos (painel, tipicamente nó no canvas) — adicionado 2026-10-18
- **Android** (emulador e celular físico): vídeo ao vivo via protocolo do **scrcpy** (Apache-2.0; `scrcpy-server.jar` com versão fixada e embutida, H.264 decodificado com VideoToolbox), input pelo socket de controle; comandos de agente via **adb** (screenshot, árvore de UI `uiautomator dump`, tap, swipe, texto, tecla, logcat, instalar, abrir app). Conecta a dispositivos já rodando; iniciar AVD é opcional/depois. Reusa o servidor adb existente (porta 5037).
- **Simulador iOS**: vídeo ao vivo via **ScreenCaptureKit** da janela do Simulator.app (API pública; não usar frameworks privados como o Maestri); comandos de ciclo de vida/logs/screenshot via `xcrun simctl` (Xcode 26 não tem tap/swipe/árvore de UI); toque, digitação e árvore de UI via **AXe** (MIT, CLI Swift único, suporta Xcode 26/27; versão fixada e revalidada a cada Xcode — usa frameworks privados) atrás de um protocolo `SimulatorInput`, com runner XCUITest/WebDriverAgent como alternativa 100% pública (início lento 10–30 s). Captura exige permissão de Gravação de Tela e janela do Simulator visível; app recorta a moldura e converte coordenadas. Verificar se AXe cobre swipe. **iPhone físico fora.**
- Motor de dispositivos roda **no daemon** (crash de adb/simulador não derruba a UI); processos por dispositivo encerrados ao fechar o painel; FPS limitado.
- Comandos sujeitos à regra de corda; eventos `device.connected`, `device.crash`, `device.app_launched`.
- Fase: após o sistema de plug-ins (planos 1F Android, 1G iOS).

---

## 8. Memória própria

### 8.1 O que guarda
- **Decisões:** o que foi escolhido, por quê, quem gravou (agente/terminal), quando, projeto/andar.
- **Mapa:** "onde fica cada coisa" — caminho + o que é. App verifica se o caminho ainda existe.
- **[call]** Tipo adicional "armadilha/aviso" (algo que deu errado antes).
- Escopos: projeto (padrão), andar, global do usuário.

### 8.2 Escrita
- **Agente grava sozinho** (decisão do usuário) via comando de memória (CLI/MCP).
- **[call]** O app lembra o agente de gravar ao fim de uma tarefa (ex.: no evento de fim de turno), e plug-ins gravam decisões automaticamente (ex.: troca de design system).
- Gravar uma decisão sobre o mesmo assunto **substitui** a anterior (cadeia de substituição), não duplica.
- **Entra nas injeções na hora, antes de qualquer revisão** **[call, derivado de "grava sozinho, reviso depois"]**, marcada com origem (qual agente/terminal, quando, não revisada). Substituição também vale na hora. Descartar na revisão remove das injeções; editar atualiza.

### 8.3 Injeção (problema central)
- **Ao abrir um terminal/sessão:** o app entrega ao agente um resumo das decisões vigentes e do mapa do projeto/andar (via hooks de início de sessão do Claude Code/Codex ou arquivo de contexto). Tamanho limitado.
- **Ao mudar de assunto:** quando o prompt menciona algo com memória relacionada, o app injeta essas memórias **antes** do agente começar a explorar (hook de prompt). Recuperação por busca textual + entidades/caminhos; vetores opcionais **[call]**.
- Meta mensurável: em tarefas repetidas, o agente usa a memória injetada em vez de reler o código.

### 8.4 Revisão (painel)
Abas: **Revisar** (o que agentes gravaram desde a última revisão: aprovar / editar / descartar), **Decisões** (com histórico de substituição), **Mapa** (marca caminhos que sumiram), **Limpeza** (o que será arquivado/mesclado/removido). Mockup em `.superpowers/brainstorm/*/content/memory-panel.html`.

### 8.5 Limpeza (inspirada no ai-memory, reescrita)
- Decisão substituída sai das injeções, fica no histórico, restaurável.
- Caminho do mapa que sumiu do disco é marcado (e sai das injeções após confirmação ou prazo **[call]**).
- Retenção com decaimento: memórias pouco lidas esfriam; leitura reforça. Fixadas não decaem.
- Mesclagem de duplicatas.
- **Nada é apagado de verdade sem o usuário**; tudo reversível.
- **[call]** Consolidação por LLM ("sonho") fora da v1.

### 8.6 Armazenamento
- **Dentro do repositório do projeto** (decisão do usuário), versionado junto com o código. Vale para **memória, documentos de design e biblioteca de design systems**.
- Layout **[call]**: `<repo>/.<app>/memory/` (markdown, um arquivo por memória, frontmatter com tipo/escopo/origem/substituição) e `<repo>/.<app>/design/` (documentos de design e design systems).
- Índice SQLite de busca é **derivado, fora do git** (gitignored, reconstruível).
- Memória de escopo global do usuário (não ligada a projeto) fica na pasta do app **[call]**.

### 8.7 Andares e "land"
- Como estão no repo, memória e design **viajam com o andar** (worktree) e **voltam no land** junto com o código.
- Design precisa ser mesclável: armazenar documentos de design como **JSON de texto** (o figcraft abre `document.json` puro), não o `.figcraft` zipado **[call]**. Conflito de design no land: o app detecta e pergunta ao usuário qual versão manter por tela (sem merge automático de JSON de design na v1) **[call]**.
- Memórias markdown mesclam como texto; conflito de cadeia de substituição é resolvido mantendo a mais recente como vigente e a outra no histórico **[call]**.

---

## 9. Captura de resposta e confiabilidade de chamadas

- **Preferência por eventos estruturados**: hooks de fim de turno do Claude Code / notify do Codex / modos stream-json, entregues ao daemon. Leitura da tela (estabilidade do buffer) só como fallback.
- Injeção de prompt no PTY permanece necessária para enviar mensagens; usar bracketed paste e respeitar estado do agente.
- Todo comando: schema versionado, erro tipado, timeout explícito, resultado nunca truncado silenciosamente.

---

## 10. Desempenho e recursos (requisitos)

- Histórico de terminal com teto em memória; excedente em disco.
- Terminais fora da tela não renderizam.
- Busca de memória, export, import de HTML e git fora da main thread.
- Processos auxiliares encerrados quando ociosos; webviews liberadas ao fechar painel.
- **Testes de desempenho contínuos** com N agentes ativos: RAM ao longo do tempo (detecção de leak), frames por segundo do canvas, taxa de falha e latência de chamadas de ferramentas. Valores-alvo de N e limites ficam com o builder **[call]**, mas precisam existir e rodar na CI.

---

## 11. Riscos (ordem de ataque)

1. **Fonte única no figcraft** (UI e agentes no mesmo documento ao vivo) — spike no início da fase 2; não bloqueia a fase 1; se falhar, trocar motor.
2. **Importar HTML → telas do figcraft** — validar com a landing page real.
3. **figcraft alpha** (9 dias, API instável): fixar versão; isolar atrás de um adaptador nosso.
4. **Injeção de memória efetiva** depende de hooks de cada agente (Claude Code, Codex); medir se o agente realmente usa.
5. Separação app/daemon adiciona complexidade de IPC — compensada pela anti-meta de quebras.

---

## 12. Deixado para o builder

Escolha exata do caminho de integração do figcraft após o spike; formato do IPC app↔daemon; lançamento do daemon (LaunchAgent vs filho); detalhes visuais do canvas; algoritmo de busca/ranking da memória; parâmetros de decaimento; valores-alvo de desempenho; estrutura de módulos Swift (SPM) do projeto.
