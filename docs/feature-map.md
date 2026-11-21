# Mapa de funcionalidades do Collie

O app do ponto de vista de quem usa: cada superfície com o nome que aparece na tela (as strings do código), para que
serve, onde está no código e como verificar. Use estes nomes ao falar de uma tela ou ao procurá-la.

Mantido à mão. `scripts/ci/lint.sh` (regra `feature-map`) falha se um `Sources/ColliePlugins/*Panel.swift` não estiver
citado aqui pelo nome do arquivo sem extensão: painel novo ganha uma seção em "Painéis".

Como verificar, em geral:

- Terminal de um agente: `collie check <nome> --screen` (a tela como está desenhada agora).
- Painel: `collie panel open <plug-in>` e `collie panel list`. Terminal que não é Pastor só abre `browser` e `preview`;
  os outros painéis abre o dono, em "Abrir painel…".
- App sem tocar no instalado: `scripts/dev/run-isolated.sh`.
- Passo à mão: o que só o dono vê (menus, cartões, folhas).

## Canvas

- **Nome na UI:** "Canvas" (menu da barra de menus, posição de painel e o botão de voltar da tela cheia).
- **Para que serve:** a área onde ficam os nós de terminal e de painel de um cercado, ligados por guias.
- **Arquivos:** `Sources/CollieApp/CanvasViewport.swift`, `Sources/CollieApp/LeashLayer.swift`, `Sources/CollieCanvas/`
  (a seleção, em `Selection.swift`), `Sources/CollieApp/NodeBatch.swift` e `NodeActions.swift` (o menu da seleção).
- **Navegar:** rolar move o canvas; Espaço + arrastar ou segurar o botão do meio (a roda) e arrastar também; o clique
  do meio sem arrastar não muda nada. Arrastar no fundo vazio desenha um retângulo de seleção.
- **Seleção:** uma só, do canvas e do painel de contexto. Clique seleciona um item; ⌘-clique alterna; ⇧-clique estende
  (no painel de contexto, vai do último clicado até o clicado); retângulo no fundo (com ⌘/⇧ soma ao que já estava);
  clique no fundo ou Esc limpa. No terminal, ⌘/⇧-clique valem na barra de título (no corpo são do próprio terminal).
  Arrastar um nó selecionado leva a seleção junto. Botão direito num nó ou linha da seleção abre o menu para todos
  ("N itens selecionados"; só o que vale para todos: "Reiniciar", "Matar", "Salvar na memória", "Lote", "Mover para",
  "Fechar N itens…", com uma confirmação que diz quantos); fora da seleção, ela passa para aquele item.
- **Como verificar:** `swift test --filter SelectionTests` e `--filter NodeActionsTests`; o resto, à mão. Clique direito no fundo: "Novo terminal aqui…", "Abrir painel aqui…",
  "Aplicar rebanho aqui…", "Reiniciar todos os terminais…", "Ajustar à tela", "Zoom 100%". Em tela cheia: "Canvas"
  (Esc), "Janela anterior", "Próxima janela", "Tamanho do terminal", "Sair da tela cheia".

### Nó de terminal

- **Nome na UI:** o nome do terminal; menu "Ações do terminal": "Tela cheia", "Editar…", "Reiniciar", "Matar",
  "Salvar na memória", "Lote", "Fechar nó…". Selos: "pastoreando N", "desconectado".
- **Para que serve:** um agente (ou shell) rodando num terminal do canvas.
- **Arquivos:** `Sources/CollieApp/TerminalNodeView.swift`, `Sources/CollieApp/TerminalDrop.swift`, `Sources/CollieTerminal/`.
- **Arrastar para o terminal:** soltar arquivos ou uma imagem cola os caminhos, com escape de shell, como o Terminal
  do macOS (colagem com marcadores quando o programa pede, e os agentes anexam a imagem). Imagem sem arquivo
  (navegador, Fotos, miniatura de captura) é gravada como PNG em `$TMPDIR/collie-drops/` antes.
- **Como verificar:** `collie list` e `collie check <nome> --screen`; `swift test --filter TerminalDropTests`;
  arrastar uma imagem do Finder para um terminal Claude, à mão.

### Nó de painel e docas

- **Nome na UI:** o título do plug-in; menu "Ações do painel": "Tela cheia", "Mover para" ("Doca esquerda",
  "Doca direita", "Doca baixo", "Canvas"), "Fechar…". Sem o plug-in: "Plug-in indisponível".
- **Para que serve:** a moldura de um painel, no canvas ou numa doca.
- **Arquivos:** `Sources/CollieApp/PanelNodeView.swift`, `Sources/CollieApp/DockView.swift`.
- **Como verificar:** `collie panel list`, `collie panel move`; os menus, à mão.

## Painéis

Títulos de `Sources/CollieProtocol/Plugins.swift` (o que aparece em "Abrir painel" → "Plug-in").

### Artifacts (`ArtifactsPanel`)

- **Nome na UI:** "Artifacts" (subtítulo "N páginas").
- **Para que serve:** lista as páginas guardadas pelos agentes, por pasta; exporta, move e remove.
- **Arquivos:** `Sources/ColliePlugins/ArtifactsPanel.swift`, `Sources/ColliePlugins/ClaudeImportSheet.swift`,
  `Sources/ColliePlugins/DeckExporter.swift`.
- **Como verificar:** `collie artifact list`; o painel, à mão.

### Browser (`BrowserPanel`)

- **Nome na UI:** "Browser".
- **Para que serve:** um navegador que o agente dirige (navegar, clicar, digitar, ler a página).
- **Arquivos:** `Sources/ColliePlugins/BrowserPanel.swift`, `Sources/ColliePlugins/BrowserCommands.swift`,
  `Sources/ColliePlugins/BrowserAutomation.swift`, `Sources/ColliePlugins/BrowserInput.swift`.
- **Como verificar:** `collie panel open browser --url <url> --visible`, depois `collie browser --help`.

### Design (`DesignPanel`)

- **Nome na UI:** "Design" (subtítulo: o arquivo). Sem o motor: botões "Abrir Preferências" e "Reconectar".
- **Para que serve:** o arquivo de design aberto no motor de design (FigCraft).
- **Arquivos:** `Sources/ColliePlugins/DesignPanel.swift`, `Sources/CollieApp/DesignEnginePreferences.swift`.
- **Como verificar:** `collie design files`; o painel, à mão ("Abrir painel" → "Design" → "Arquivo").

### Design Systems (`DesignSystemsPanel`)

- **Nome na UI:** "Design Systems" no seletor de plug-in; "Design systems" no cabeçalho do painel.
- **Para que serve:** escolhe o design system de cada escopo, publica versão e volta no "Histórico".
- **Arquivos:** `Sources/ColliePlugins/DesignSystemsPanel.swift`.
- **Como verificar:** `collie design --help` (comandos `system`); o painel, à mão ("Usar neste escopo",
  "Publicar versão", "Voltar para esta versão").

### Dispositivo (`DevicePanel`)

- **Nome na UI:** "Dispositivo". Botões: "Início", "Bloquear" (iOS); "Voltar", "Início", "Recentes" (Android);
  "Reconectar".
- **Para que serve:** a tela de um emulador Android, simulador iOS ou aparelho, com toque e teclado.
- **Arquivos:** `Sources/ColliePlugins/DevicePanel.swift`, `Sources/CollieDevice/`.
- **Como verificar:** `collie device list`; o painel, à mão ("Abrir painel" → "Dispositivo" → "Aparelho").

### Diagrama (`DiagramPanel`)

- **Nome na UI:** "Diagrama" (subtítulo: o arquivo). Em erro: "Tentar de novo".
- **Para que serve:** mostra e edita um diagrama que o agente desenha.
- **Arquivos:** `Sources/ColliePlugins/DiagramPanel.swift`, `Sources/ColliePlugins/DiagramCommands.swift`.
- **Como verificar:** `collie diagram --help`; o painel, à mão.

### Memória (`MemoryPanel`)

- **Nome na UI:** "Memória". Seções e ações: "Precisa de você", "Parece uma correção sua — confirmar?",
  "Lote <nome>", "Aplicar limpeza", "Esvaziar descartadas…", "Editar memória".
- **Para que serve:** revisar o que os agentes aprenderam: aprovar, editar, descartar e limpar memórias.
- **Arquivos:** `Sources/ColliePlugins/MemoryPanel.swift`, `Sources/ColliePlugins/MemoryObservability.swift`.
- **Como verificar:** `collie memory list`, `collie memory stats`; o painel, à mão.

### Rede (`NetworkPanel`)

- **Nome na UI:** "Rede". Abas "Fluxos" e "Regras (N)"; ações "Limpar", "URL", "cURL", "Mapear", "Salvar regra".
- **Para que serve:** inspeciona as requisições de um emulador e responde no lugar do servidor por regra.
- **Arquivos:** `Sources/ColliePlugins/NetworkPanel.swift`, `Sources/ColliePlugins/NetworkPanelView.swift`,
  `Sources/CollieNetwork/`.
- **Como verificar:** `collie network --help`; o painel, à mão, com um emulador ligado.

### Prévia (`PreviewPanel`)

- **Nome na UI:** "Prévia" (subtítulo: pasta · arquivo).
- **Para que serve:** mostra uma página HTML do agente (deck, dashboard, doc, protótipo), com comentários.
- **Arquivos:** `Sources/ColliePlugins/PreviewPanel.swift`, `Sources/ColliePlugins/PreviewComments.swift`.
- **Como verificar:** `collie artifact new doc` abre uma Prévia; `collie comment list`.

### Trabalho (`WorkPanel`)

- **Nome na UI:** "Trabalho" (subtítulo "N ativos"). Selo "em laço: <tarefa> (tentativa n/m)"; seção "Fechados (N)".
- **Para que serve:** o registro do que cada terminal está fazendo, com tarefas e o andamento do laço. A tarefa feita pelo
  laço mostra a evidência: commits, saída do check e os arquivos de evidência declarados (`--evidence`), com "Abrir".
- **Laço em paralelo:** `collie work run --parallel <n>` (padrão 1, máximo 4) roda cada tarefa numa faixa (worktree
  temporário do laço, não um cercado) e integra uma de cada vez; `work task add --scope --needs` diz quem pode rodar
  junto (sem `--scope` a tarefa roda sozinha). O `work status` mostra uma linha por faixa. Ver `docs/referencia.md`.
- **Arquivos:** `Sources/ColliePlugins/WorkPanel.swift`.
- **Como verificar:** `collie work status` (a linha do laço diz `desde HH:mm (N min)` e, com o agente trabalhando,
  `próximo limite: turno vence em N min`), `collie work wait [--since N] [--timeout S]` (espera o trabalho mudar, sem
  terminal; devolve a versão), `collie work list`, `collie work task reopen <tarefa> [--keep-tries]` (uma tarefa adiada
  ou abandonada volta à fila, na mesma posição, com `spec` e `check`); o painel, à mão.
- **Tokens por tentativa:** `collie work status` mostra `tokens: <índice relativo> · N msgs` do trabalho (só contagens
  do transcript de cada agente do laço); `collie work usage [--limit N]` lista os trabalhos do cercado com o total e por tarefa.
- **Resumo imutável (T6.1):** ao fechar (`work done`, ou o fim do laço de um trabalho já fechado) o daemon grava uma vez
  `<raiz>/work/work-archive/<id>.json` (`-2`, `-3`… a cada novo fechamento; diário até 500 eventos; ≤ 1 MB; os 200 mais
  novos ficam). `collie work history [--limit N] [--id <trabalho>]` (MCP `work_history`) lista só os do seu cercado.

### Plug-ins externos e apps (`WebPluginPanel`)

- **Nome na UI:** o nome do plug-in ou do app. Avisos: "Plug-in <nome> não pôde ser carregado",
  "<nome>: iniciando o serviço…", "<nome> parou: …", "Tentar de novo".
- **Para que serve:** hospeda a página de um plug-in de terceiros ou de um app do cercado, sem rede.
- **Arquivos:** `Sources/ColliePlugins/WebPluginPanel.swift`, `Sources/ColliePlugins/PluginPanelView.swift`,
  `Sources/ColliePlugins/WebLockdown.swift`, `Sources/CollieCore/PluginManifest.swift`.
- **Como verificar:** `collie plugin --help`, `collie app list`; instalar é à mão (Preferências → "Plug-ins").

### Vizinho e Cercas (plug-in de exemplo com ganchos `edit` e `stop`)

- **Para que serve:** (1) `edit`: depois que um terminal Claude escreve um arquivo, o helper olha os irmãos (mesma pasta,
  extensão e sufixo de tipo, ex.: `*Panel.swift`) e devolve ao agente a forma que quase todos seguem (95% ou mais), com um
  arquivo modelo ("19 de 20 importam A; este não importa"). (2) `stop`: Cercas. O helper minera convenções quase
  unânimes (grupos de 10+ arquivos: `require-import`, `require-test`, `forbid-import`) e grava as propostas em
  `propostas.json`; o dono aprova copiando a cerca para `cercas.json`, e a partir daí o fim do turno é bloqueado
  enquanto um arquivo do turno a quebra. Arquivos que já quebravam ficam no `baseline` e saem dele sozinhos quando corrigidos
  (a catraca; o `baseline` nunca cresce). Sem configuração além disso.
- **Onde ficam os arquivos:** `$COLLIE_PLUGIN_DATA/<chave>/` (pasta de dados do plug-in, fora do projeto), `<chave>` = 16 hex do
  SHA-256 da raiz do repositório (worktrees dividem a do repositório principal). `propostas.json` é do plug-in (regravado
  a cada 24 h); `cercas.json` é do dono (o plug-in só reduz o `baseline`).
- **Nome na UI:** "Vizinho" (painel mínimo explicando isso); a orientação e o bloqueio chegam ao agente com o prefixo "[plug-in vizinho]".
- **Arquivos:** `Sources/VizinhoKit/Vizinho.swift`, `Sources/VizinhoKit/Fences.swift`, `Sources/VizinhoKit/Mining.swift`,
  `Sources/collie-vizinho/main.swift`, `Examples/plugins/vizinho/`, `scripts/build-vizinho-plugin.sh`,
  `Tests/VizinhoKitTests/`, `Tests/CollieIntegrationTests/VizinhoPluginTests.swift`.
- **Como verificar:** `swift test --disable-sandbox --filter VizinhoKitTests`;
  `scripts/build-vizinho-plugin.sh && swift test --disable-sandbox --filter VizinhoPluginTests`;
  na mão: instalar `.build/plugins/vizinho` em Preferências → "Plug-ins", pedir a um terminal Claude um `*Panel.swift` novo
  e, depois de um turno, ler `propostas.json` na pasta de dados.

## Menus e cartões do app

### Barra de menus

- **Nome na UI:** "Exportar dados do Collie…", "Importar dados do Collie…", "Comandos…" (⌘K), menu "Canvas" →
  "Rebanhos…", "Parar serviço".
- **Para que serve:** backup dos dados, abrir a paleta e os rebanhos, parar o serviço em segundo plano.
- **Arquivos:** `Sources/CollieApp/CollieApp.swift`.
- **Como verificar:** à mão.

### Barra do cercado

- **Nome na UI:** "Ações do cercado" ("Status", "Land", "Excluir…"), "Novo cercado…", "Menu do cercado",
  "Novo terminal", "Abrir painel…", "Comando", "Uso dos agentes", "Zoom", "Preferências".
- **Para que serve:** trocar de cercado, criar cercado e terminal, ver o uso dos agentes.
- **Arquivos:** `Sources/CollieApp/Shell.swift`, `Sources/CollieApp/PaddockBar.swift`,
  `Sources/CollieApp/PaddockRail.swift`, `Sources/CollieApp/ContextPanel.swift` (estrutura Completa: o trilho de
  cercados, o painel de contexto, com "AGENTES" em árvore e "PAINÉIS" (seleção compartilhada com o canvas: ⌘ alterna,
  ⇧ marca o intervalo, botão direito abre o menu do item ou da seleção), e a faixa de abas "Canvas" / "Preferências"
  com "Comando" e "Zoom"), `Sources/CollieApp/MainView.swift`, `Sources/CollieApp/UsagePopover.swift`.
- **Como verificar:** `collie paddock list`; os menus, à mão.

### Paleta de comandos

- **Nome na UI:** "Comando" (⌘K), campo "Chamar, abrir painel, ir para cercado…".
- **Para que serve:** chamar um agente, abrir um painel ou ir a um cercado pelo teclado.
- **Arquivos:** `Sources/CollieApp/CommandPalette.swift`.
- **Como verificar:** à mão.

### O que o Collie faz

- **Nome na UI:** ícone de informação ("O que o Collie faz") no pé do trilho, acima do uso, e na barra Compacta, à
  esquerda do uso; abre a folha "O que o Collie faz" (abas Trabalhar, Painéis, Controle, Personalizar; "Anterior",
  "Próxima", "N de 17"). Um ponto na cor de destaque no ícone enquanto houver cartão não visto.
- **Para que serve:** um carrossel com um cartão por funcionalidade (o que é, "Como chamar" e um botão que leva até
  ela). Não abre sozinho. ← e → trocam de cartão, Esc fecha. Os cartões vistos ficam em `tour.seen` (UserDefaults).
  A tabela dos cartões é a fonte: o lint (regra `feature-tour`) exige que todo `*Panel.swift` de `ColliePlugins` esteja
  citado em `panels` de algum cartão.
- **Arquivos:** `Sources/CollieApp/FeatureTour.swift` (a tabela, o modelo e os vistos),
  `Sources/CollieApp/FeatureTourView.swift` (o ícone, a folha e as 17 ilustrações), `Sources/CollieApp/PaddockRail.swift`
  e `Sources/CollieApp/Shell.swift` (o ícone), `Sources/CollieApp/CollieApp.swift` (abre a folha e executa o botão),
  `docs/pages/funcionalidades/index.html` (o protótipo aprovado).
- **Como verificar:** `swift test --disable-sandbox --filter FeatureTourTests` e `scripts/ci/test-lint.sh`; a folha, o
  ponto, as ilustrações nos temas e cada botão, à mão.

### Folha do terminal

- **Nome na UI:** "Criar terminal" / "Salvar e reiniciar"; opções "Pastor", "Terminal livre (sem sandbox)", "Lote".
- **Para que serve:** criar ou editar um terminal: comando, pasta, preset, se é Pastor.
- **Arquivos:** `Sources/CollieApp/TerminalSheet.swift`.
- **Como verificar:** à mão; o resultado, com `collie list`.

### Abrir painel

- **Nome na UI:** "Abrir painel": "Plug-in", "Posição", "Aparelho", "Arquivo", "Armazenamento" ("Isolado",
  "Workspace", "Global").
- **Para que serve:** escolher o plug-in e onde o painel abre.
- **Arquivos:** `Sources/CollieApp/OpenPanelSheet.swift`.
- **Como verificar:** à mão; o resultado, com `collie panel list`.

### Rebanhos

- **Nome na UI:** "Rebanhos" ("Importar…", "Exportar…", "Aplicar…", "Criar cercado") e "Salvar como rebanho".
- **Para que serve:** times prontos: terminais, painéis, guias e cercado.
- **Arquivos:** `Sources/CollieApp/HerdsSheet.swift`, `Sources/ColliePlugins/HerdsModel.swift`,
  `Sources/CollieCore/Herd.swift`.
- **Como verificar:** `collie herd --help`; a folha, à mão.

### Lotes

- **Nome na UI:** "LOTES" no painel de contexto: "Novo lote…", "Abrir quadro", "Apagar lote…"; abas "Quadro" e "Liberados".
- **Para que serve:** agrupa terminais de um mesmo esforço, com um quadro de recados.
- **Arquivos:** `Sources/CollieApp/Shell.swift`.
- **Como verificar:** `collie lot list`, `collie lot board`.

### Cartões de acesso e de aprovação

- **Nome na UI:** cartões com "Negar", "Liberar este caminho", "Liberar a pasta", "para o lote"; "Conectar" /
  "Recusar" (pedido de guia); "Permitir nesta sessão" (comando de app); "Responder no lugar do servidor?" (rede);
  "LIBERADOS PARA ESTE TERMINAL", "Revogar".
- **Para que serve:** o dono aprova o que um agente pede fora do sandbox; um agente nunca aprova.
- **Arquivos:** `Sources/CollieApp/AccessViews.swift`, `Sources/CollieApp/Notifier.swift`.
- **Como verificar:** `collie access request <caminho> --write --reason "…"` faz o cartão aparecer; `collie access list`.

### Preferências

- **Nome na UI:** "Preferências" (⌘,). Páginas: "Aparência", "Terminal e fontes", "Atualizações" (grupo "Interface");
  "Desenho e sandbox", "Memória", "Plug-ins" (grupo "Agentes"); "Celular", "Android" (grupo "Dispositivos").
- **Para que serve:** aparência, fontes, atualização, sandbox, curador da memória, plug-ins, iPhone pareado, Android.
  Na estrutura Completa a aba "Preferências" as mostra no lugar do canvas, que continua vivo por baixo: ⌘,, o comando
  "Preferências…", a engrenagem do trilho e "Abrir Preferências" abrem a aba (Esc ou a aba "Canvas" voltam, na mesma
  página ao reabrir); na Compacta abrem a janela de Ajustes.
  "Aparência" tem a galeria de temas: cartões Escuro, Claro e Sistema, os temas do usuário (arquivos JSON em
  `~/Library/Application Support/Collie/themes/`) e os quebrados (com o motivo; não selecionam). "Novo a partir de…"
  copia um tema válido ("<nome> (cópia)") e o seleciona; "Importar…" aceita só `.json` válido; "Mostrar no Finder"
  abre a pasta; apagar (menu de contexto, com confirmação) manda o arquivo para o Lixo e, se era o selecionado,
  volta para Escuro. Arquivo do selecionado que muda no disco é reaplicado; que some ou quebra volta para Escuro.
  Na partida o tema salvo (`custom:<id>`) é aplicado antes da primeira janela; ausente ou quebrado aplica Escuro e
  mantém a preferência.
  Abaixo da galeria, com um tema do usuário selecionado e válido, aparece o editor: nome editável, "estende
  Escuro/Claro", nome do arquivo e o seletor **Lista | JSON** (duas vistas do mesmo arquivo), com a prévia à direita
  (embaixo se couber menos de 720 pt). Lista: os 18 papéis em Fundos, Texto, Destaques e Outros, cada um com seletor
  de cor, hex (com ou sem `#`; inválido volta ao anterior), "alterado" com voltar ao herdado ou "herdado" e a leitura
  de contraste ("5,8"; "3,7 baixo" em cor de atenção). JSON: texto sem correção automática; inválido mostra "não
  aplicado: …" e nada muda. O arquivo é gravado 300 ms depois da última mudança válida (e ao sair da página ou fechar
  a janela); erro de gravação mostra uma linha e mantém o texto. Arquivo alterado por fora recarrega o editor, se não
  houver edição pendente; com pendência a edição vence. A prévia usa só a paleta em edição.
- **Arquivos:** `Sources/CollieApp/PreferencesView.swift`, `Sources/CollieApp/PreferencePage.swift`,
  `Sources/CollieApp/UpdatePreferences.swift`, `Sources/CollieApp/CuratorPreferences.swift`,
  `Sources/CollieApp/CursorMemoryPreferences.swift`, `Sources/CollieApp/PluginsPreferences.swift`,
  `Sources/CollieApp/CelularPreferences.swift`, `Sources/CollieApp/AndroidPreferences.swift`,
  `Sources/CollieApp/DesignEnginePreferences.swift`, `Sources/CollieApp/ThemeGallery.swift`,
  `Sources/CollieApp/ThemeLibrary.swift`, `Sources/CollieApp/ThemeEditorView.swift`,
  `Sources/CollieApp/ThemePreview.swift`.
- **Como verificar:** `swift test --disable-sandbox --filter 'ThemeEditorTests|ThemeEditorModelTests'` (coordenador
  com relógio injetado) e, à mão no app: trocar três cores na Lista e vê-las no JSON; editar o JSON e ver a Lista
  mudar; deixar o JSON inválido (o app não muda); salvar o arquivo num editor externo (o editor recarrega); com um
  terminal rodando um comando, nada é recriado; conferir "baixo" numa leitura com pouco contraste.

### Atualização e serviço

- **Nome na UI:** "Procurar agora", "Baixar o dmg", "Voltar e reabrir"; alerta "Reiniciar serviço" / "Depois";
  consentimento inicial "Continuar" / "Sair".
- **Para que serve:** instalar versão nova do app e manter o serviço (`collied`) na mesma versão.
- **Arquivos:** `Sources/CollieApp/UpdateInstallSheet.swift`, `Sources/CollieApp/UpdateModel.swift`,
  `Sources/CollieApp/CollieApp.swift`.
- **Como verificar:** à mão; `scripts/ci/test-update-manifest.sh` e `scripts/ci/test-update-pin.sh` cobrem o manifesto.

## CLI (`collie <grupo>`)

- **Nome na UI:** `collie <grupo> <comando>`; a lista inteira sai de `collie --help`.
- **Para que serve:** o que os agentes (e o dono, no terminal) pedem ao Collie.
- **Arquivos:** `Sources/collie/CLI.swift`, `Sources/collie/MCPServer.swift`,
  `Sources/CollieDaemonKit/CommandRouter.swift`; texto em `docs/referencia.md`.
- **Como verificar:** `collie <grupo> --help` e o próprio comando com `--json`.

| Grupo | Para que serve | Superfície ligada |
| --- | --- | --- |
| `list`, `check`, `ask`, `wait`, `reply`, `model` | ver, ler e falar com os agentes ligados por guia | Nó de terminal |
| `summon`, `dismiss`, `leash`, `unleash` | criar e ligar agentes | Canvas |
| `notify`, `open` | avisar o dono; abrir URL ou app | Notificações |
| `paddock` | criar, listar, dar status, land e excluir cercados | Barra do cercado |
| `panel`, `events` | abrir, mover, fechar e listar painéis; eventos dos plug-ins | Nó de painel e docas |
| `browser` | dirigir um painel Browser | Browser |
| `device`, `android` | aparelhos, emuladores e o SDK Android | Dispositivo, Preferências → "Android" |
| `network` | fluxos e regras do interceptador | Rede |
| `design`, `font` | arquivos de design, design systems e fontes | Design, Design Systems |
| `diagram` | desenhar no painel Diagrama | Diagrama |
| `artifact`, `preview`, `comment` | páginas guardadas, Prévias e comentários | Artifacts, Prévia |
| `memory` | memória do projeto: salvar, buscar, revisar, curador | Memória |
| `work` | registro de trabalho e o laço (`work run`) | Trabalho |
| `lot` | lotes e o quadro de recados | Lotes |
| `herd` | rebanhos | Rebanhos |
| `access` | pedir e listar liberações do sandbox | Cartões de acesso |
| `plugin`, `app` | plug-ins externos e apps do cercado | Plug-ins externos e apps |
| `admin` | comandos do app e do dono (não dos agentes) | Preferências |
