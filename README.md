# Orq

Daemon (`orqd`), CLI (`orq`) e app de canvas (SwiftUI/AppKit) para orquestrar terminais. Swift 6.2, macOS 15.

## Build

```sh
swift build
swift test
scripts/bundle-app.sh   # gera build/Orq.app (assinado ad hoc)
```

## Instalar

Copie `build/Orq.app` para `/Applications` **antes do primeiro uso**. O `orqd` roda via launchd; se o app estiver em
`~/Documents`, `~/Desktop` ou `~/Downloads`, o daemon trava na permissão de pastas (TCC) do macOS. O app avisa quando
detecta isso.

**Atualizar:** substitua o `Orq.app` em `/Applications`. O serviço (`orqd`) continua rodando a versão antiga até ser
reiniciado: o app detecta isso e mostra um aviso com **Reiniciar serviço** (encerra os terminais abertos; nunca
reinicia sozinho). Manualmente: `launchctl kickstart -k gui/$(id -u)/dev.orq.daemon`.

## Aparência

**Preferências** (⌘,):

- **Tema:** Escuro, Claro ou Sistema (segue Ajustes do macOS > Aparência). Vale para todas as janelas, sem reiniciar.
- **Estrutura:** Compacta (barra de andares em chips, janela pode ser estreita) ou Completa (barra lateral com andares e uso).
  Trocar não recarrega painéis nem move nós.
- **Fonte do terminal:** DM Mono, SF Mono ou Menlo, tamanho de 11 a 16. Os terminais abertos reajustam na hora.

**⌘K** abre a paleta de comandos: Novo terminal, Abrir painel…, Novo andar…, Ir para o Térreo, Ir para o andar …,
Ajustar à tela, Uso dos agentes e Preferências…. Digite para filtrar, ↑/↓ para escolher, ↩ para executar, Esc para fechar.

**Fontes:** o app usa Space Grotesk (interface) e DM Mono (terminal e código). Baixe-as antes do bundle:

```sh
scripts/fetch-fonts.sh    # vendor/fonts (fixado por SHA-256)
scripts/bundle-app.sh
```

Sem esse passo o bundle sai com um aviso e o app usa as fontes do sistema. As duas famílias são licenciadas sob a
SIL OFL 1.1; o aviso vai em `Orq.app/Contents/Resources/NOTICE-fonts` (fonte: `Resources/NOTICE-fonts`).

## Dispositivos Android

O plug-in **Dispositivo** mostra a tela de um Android no canvas (vídeo do scrcpy, com mouse e teclado) e dá aos agentes
comandos `orq device …` via adb, rodados pelo daemon.

1. Instale o adb: `brew install --cask android-platform-tools`.
2. No aparelho, ative **Opções do desenvolvedor → Depuração USB**, conecte por USB e aceite a chave do Mac (ou use
   um emulador). `adb devices` deve mostrar o aparelho como `device`.
3. Antes do bundle, baixe o servidor do scrcpy (fixado em v3.3.1, conferido por SHA-256):

   ```sh
   scripts/fetch-scrcpy-server.sh   # vendor/scrcpy-server
   scripts/bundle-app.sh            # copia para o Orq.app
   ```

4. No app, **Abrir painel… → Dispositivo**, escolha o aparelho (botão **Atualizar** relê a lista). Ou um Maestro:
   `orq panel open device --serial <serial>` (sem `--serial`: o único aparelho online).

No painel: clique/arraste = toque, rolagem = scroll, teclado com o painel em foco (acentos inclusive); a barra tem
**Voltar**, **Início** e **Recentes**. Sem aparelho, o painel mostra o estado e **Reconectar**.

Comandos (um terminal precisa de um cordão até o painel do canvas; painel na doca vale para todos):

```sh
orq device list                     # aparelhos {serial,state,model,product,panels}
orq device screenshot               # PNG; devolve {path,width,height}
orq device ui                       # árvore de UI com refs (e1, e2, …)
orq device tap 540 1200             # ou: orq device tap --ref e3
orq device swipe 540 1800 540 600
orq device text "ola mundo"
orq device key Back                 # Enter, Home, ... ou um keycode
orq device logcat --lines 100 --grep MyApp
orq device install app.apk
orq device launch com.example.app
```

Limitações: sem áudio; `device.text` só ASCII e não digita `%s` literal (é o
`input text` do Android; acentos e `%s`, digite pelo painel); um ANR não vira evento (só crashes do buffer de crash do logcat).

Emuladores instalados e desligados aparecem em `orq device list` e na folha como `avd:<nome>` (`state: "off"`). Abrir o painel
de um liga o emulador e espera o boot (até 3 min); com `orq panel open device --serial avd:<nome>` é igual. O emulador roda em
sessão própria, então parar ou reiniciar o serviço não o derruba. O Orq nunca o desliga: fechar o painel ou parar o serviço o
deixa ligado. `ORQ_EMULATOR` aponta um binário `emulator` fora do SDK padrão.

## Simulador iOS

O mesmo plug-in **Dispositivo** mostra um Simulador iOS (vídeo e entrada pelo [AXe](https://github.com/cameroncooke/AXe), comandos
via `simctl`).

1. Xcode 26+ com um runtime iOS instalado (`xcrun simctl list devices` deve listar simuladores).
2. Instale o AXe: `brew install cameroncooke/axe/axe` (testado com o AXe 1.8.0).
3. No app, **Abrir painel… → Dispositivo**: os simuladores aparecem como `iPhone 16e — iOS 26.3`, e os desligados com
   `(desligado)`. Abrir o painel de um simulador desligado o liga (pode levar até ~2 min). Ou um Maestro:
   `orq panel open device --serial <UDID>`.

No painel: clique = toque, arrastar = um swipe ao soltar, rolagem = swipe a partir do centro, teclado com o painel em
foco; a barra tem **Início** e **Bloquear**. Os comandos `orq device …` valem para o simulador, com coordenadas em
**pontos** (não pixels): `orq device list` mostra `platform: "ios"`, o UDID como `serial` e o estado (`booted`, `shutdown`).

Limitações: só simulador (iPhone físico não); `device.text` só digita teclado US (ASCII); sem botões de volume/Siri na
barra; um arrasto vira um único swipe ao soltar (sem seguir o dedo, sem multitoque); o vídeo e a entrada dependem de o AXe
acompanhar o Xcode (ele usa frameworks privados: uma atualização do Xcode pode quebrá-los até sair um AXe novo).

## Design

O plug-in **Design** é o [figcraft](https://github.com/storytold/figcraft) v0.7.0 (fixado, sem a marca ArtCraft e sem
servidor público) embutido: o daemon roda um `figcraft-server` local (só `127.0.0.1`) e o painel mostra a UI web dele ao
vivo; os agentes editam o mesmo arquivo pela CLI, na mesma sessão.

1. Pré-requisito: `rustup` com o alvo wasm (o Rust do Homebrew não serve):
   `brew install rustup && rustup-init -y --no-modify-path && rustup target add wasm32-unknown-unknown`.
2. `scripts/build-figcraft.sh` (gera `vendor/figcraft/{bin,web,licenses}`; a primeira vez leva ~10 min), depois
   `scripts/bundle-app.sh` (copia para `Contents/Resources/figcraft`). Rodando com `swift run`, aponte
   `ORQ_FIGCRAFT_DIR=$PWD/vendor/figcraft` para o daemon.
3. No app, **Abrir painel… → Design**: escolha um arquivo ou digite um nome em **Novo arquivo…** e clique **Criar**.
   O painel abre o figcraft já dentro da sessão do arquivo, numa aba, sem o diálogo "Entrar" (o link vem só do daemon;
   um link ruim mostra o erro do figcraft). Ou um Maestro: `orq panel open design --file <nome>` (cria se não existir).

Comandos dos agentes (`orq design …`, ligados ao painel por um cordão; `--panel <nome>` se houver mais de um): `files`,
`new <nome>`, `run <comando> --params '{…}'`, `batch --commands '[…]'` (um passo de desfazer, tudo ou nada), `inspect`,
`screenshot`, `export --format html|css|react|figcraft`, `help [busca]`. `export --format figcraft` é recusado num arquivo
que usa design systems (o `.figcraft` levaria os links das bibliotecas): exporte html, css ou react.

O export HTML agora gera um artifact versionado (veja a seção Artifacts).

Limitações: os arquivos ficam no armazenamento do servidor local (não no git; `export --format figcraft` gera um
`.figcraft`); o painel usa WebGPU quando o WebKit tem um adaptador (sonda única por execução, prazo de 2 s) e WebGL2 (`?webgl`) caso contrário; se a página WebGPU não iniciar, recarrega com `?webgl`. `ORQ_DESIGN_GPU=webgl|webgpu` força um dos dois. Medido em macOS 15 (Darwin 24.6, arm64): a sonda respondeu false nesta máquina; o figcraft registrou o backend Gl com e sem ?webgl. Servidor, CLI e UI são sempre a mesma versão (v0.7.0). Limitações da importação de HTML: veja a seção Importar HTML.

## Design systems

Um **design system** é um arquivo de design (figcraft) com variáveis (tokens, com modos), estilos e componentes, publicado em
versões. Um deles pode ser o **ativo** do workspace (o padrão de todos os andares) e cada andar pode ter o seu. Ao trocar o
ativo, os arquivos de design daquele escopo passam a usar a biblioteca do novo, e os agentes recebem os tokens por
`orq design system tokens`.

No app: **Abrir painel… → Design Systems**. Escreva o **motivo** (obrigatório em toda alteração) e use:
**Novo design system…** (do zero ou a partir de outro), **Usar neste escopo** (Workspace ou um andar), **Desfazer troca**,
**Publicar versão** e, no **Histórico**, **Voltar para esta versão**. Depois de cada ação o painel mostra o resultado por
arquivo e o que ficou **sem par** (`unmatched`). Se a publicação for recusada porque o sistema "voltou" e o arquivo ainda
mostra o conteúdo mais novo, o painel mostra a mensagem e oferece **Publicar mesmo assim** (com confirmação).
O painel atualiza ao abrir, depois de cada ação e quando o evento `designsystem.changed` chega (no máximo uma vez a cada 500 ms).

Comandos (`orq design system …`): `list`, `history <nome>`, `create <nome> [--from <outro>] --reason`,
`publish <nome> --reason [--force]`, `use <nome> [--floor <andar>] --reason` (ou `--none`), `undo [--floor <andar>] --reason`,
`revert <nome> --to <versão> --reason`. Para os agentes trabalharem com o sistema ativo do arquivo do painel:
`tokens`, `bind --variable <nome> --field <campo> --ids …`, `style --style <nome> --ids …`, `place --component <nome>`,
`mode --mode <Light|Dark> [--collection <coleção>]` (padrão: `Tokens`, a coleção do sistema inicial).

`undo` alterna entre os dois últimos sistemas do escopo (um segundo `undo` volta ao de antes); para um mais antigo, use o
**Histórico** do painel (ou `use`). `create` não precisa de cordão (`--from` copia o arquivo, e a biblioteca da cópia leva o
nome novo). Se um `create` falhou no meio, repeti-lo adota o arquivo deixado; um arquivo adotado cuja biblioteca já saiu
sem mudanças é recusado com "no changes to publish": edite-o e crie de novo.

Quem pode trocar: no workspace, o usuário no app ou um Maestro no térreo (um Maestro num andar usa `--floor`); no andar, o
usuário, o Maestro que o criou ou um Maestro que está num andar criado pelo usuário. `publish` e `revert` por um terminal
exigem um cordão com o painel Design do sistema. Cada alteração vira uma decisão na Memória: as do workspace e de
`publish`/`revert` na memória global, as de um andar no repositório do andar (a mais nova substitui a anterior, venha de quem
vier). Excluir um andar com sistema próprio aplica o do workspace aos arquivos dele e registra a decisão.

Limitações: a troca casa por nome (variáveis por coleção+nome+tipo, estilos por nome+tipo, componentes e variantes por
nome); o que não casa continua no design system anterior e aparece em `unmatched`. A UI web do figcraft não opera
bibliotecas: troque/publique/volte pelo painel ou pelos comandos. "Voltar" cria uma versão nova e marca o sistema: antes da
próxima publicação é preciso editar o arquivo de volta ou usar `--force`. A troca entre arquivos não é transacional (uma
falha não desfaz os outros; o resultado vem por arquivo).

## Artifacts

Um **artifact** é uma página HTML guardada em versões. Todo `orq design export --format html [--node <id>]` vira um: o
export passa por um pós-processador (`h1`/`section`/`ul`/`a`, reset de CSS, tokens das variáveis com os modos Light/Dark em
`[data-theme]`, grid, SVG inline, layout responsivo básico) e é gravado em `<raiz>/artifacts/<id>/v<N>/index.html`, com
miniatura. Exportar de novo o mesmo (arquivo, nó) — ou, sem `--node`, a mesma página do arquivo (cada página tem o
seu artifact) — cria a versão seguinte do mesmo artifact. Qualquer terminal também pode
registrar uma página que ele mesmo fez (`artifact.add`): fica em `<raiz>/artifacts/<id>/source.html` (com `--root`, a
pasta em `<raiz>/artifacts/<id>/source/…`), somente leitura, e é importada como tela (veja Importar HTML).

No app: **Abrir painel… → Artifacts** (miniatura, origem, versão, status `current`/`stale`/`missing`/`unknown`/`pending`).
**Abrir no Navegador** carrega `orq-artifact://app/<id>/v<N>/index.html`; **Reexportar** gera a versão nova (marca
**desatualizado** quando o design mudou depois do export); **Remover** move a pasta para `artifacts/.removed`.

Comandos (`artifact.*`): `list`, `get <id>`, `add <caminho.html> [--root <pasta>] [--title] [--width <px>]` (o caminho é
resolvido contra o cwd e caminhos absolutos são aceitos; `.html`/`.htm`, sem symlink, até 8 MB), `import <id> [--width <px>]`
(largura 320–3840, padrão 1440), `reexport <id>` e `remove <id>` (só o app).

O painel também atualiza sozinho com os eventos `artifact.*` (no máximo uma vez a cada 500 ms); falha de importação em segundo plano chega como `artifact.imported` com `error`.

Limitações: as fontes não vão embutidas (fallback do sistema).
Links só de camada inteira; trechos com link dentro do texto saem sem `<a>` (a saída `<a>` é
coberta por fixtures unitárias e pelo teste com o motor real). Fundo-imagem de frame com filhos não é exportado. Todos
os artifacts compartilham a origem `orq-artifact://app` no Navegador (HTML de agente pode ler outros artifacts locais).
Agentes podem usar `text.link` (e `hyperlink` em `text.style`/`node.set`) com http(s), mailto, tel, `#âncora` ou caminho relativo; outros esquemas (`javascript:`, `data:`) são recusados. Não podem usar `image.place` com caminho em `design run/batch`.

## Importar HTML

Uma página registrada por um agente vira uma **tela editável**: `orq artifact add <página.html> [--root <pasta>] [--title]`
guarda a página e começa a importação em segundo plano (status `importing`). Com `--root`, a pasta inteira (css, js,
imagens, fontes; até 2000 arquivos e 64 MiB, sem links) é arquivada em `<raiz>/artifacts/<id>/source/` e a página precisa
estar dentro dela. O app abre a página num WKWebView invisível (JS da página ligado, largura 1440 por padrão), lê o DOM e
os estilos calculados e o daemon transforma isso em comandos figcraft num único `batch` (um passo de desfazer): um
arquivo de design novo (nome = título), com o design system do andar habilitado, e uma tela com frames (flex/grid viram
auto layout/grid), textos com estilos por trecho, imagens e SVGs. A tela é exportada de volta para o próprio artifact,
que vira `current`; a página original continua como origem.

No painel Artifacts: **importando…**, **falha na importação** (o motivo no balão do status) e **atual**; **Abrir origem**
abre a página original no Navegador para comparar; **Importar de novo** (quando falhou) e **Importar** (quando ficou
`pending`, p. ex. uma página do 2C ou uma importação cortada por reinício do daemon) importam com o app aberto.
Por um terminal: `orq artifact import <id> [--width 390]` (ou já no `add --width 390`).

Limites: o **app precisa estar aberto** (sem ele o artifact fica `failed`); a **rede fica bloqueada** (http/https/ws/ftp):
só carrega o que está na pasta, e fontes da web caem para as fontes locais (Inter quando a família não existe no motor);
até 3000 elementos; a página é lida no estado em que carrega (sem cliques, sem rolagem). O resultado é uma
**aproximação** para continuar editando, não uma cópia pixel a pixel: pseudo-elementos (`::before/::after`), `transform`,
animações, `position: sticky`, iframes e vídeo não entram (ou entram como caixa); campos entram só com o texto (senha
mascarada; checkbox, radio, range e arquivo como caixa); gradientes lineares ignoram a proporção da caixa e radiais
viram uma elipse por camada; `clip-path` só `inset(…)` (os outros saem sem recorte, com aviso); imagens vêm reduzidas a
até 2× a caixa. Um `<button>` com ícone ou outros elementos vira um frame (só o de texto puro vira texto com caixa); SVG
em linha sai com as cores calculadas (`currentColor` resolvido). Espaços de um flex sem quebra (margens, `flex: 1`,
`justify-content`) viram frames vazios "spacer" com alinhamento `min`; filhos sobrepostos tiram o auto layout desse frame
(aviso).
Com um design system ativo, cada cor sólida e opaca de preenchimento ou borda (de frames e textos inteiros) com o mesmo valor de
uma variável de cor do sistema (o primeiro modo; empate: o nome em ordem alfabética) é ligada a ela, num passo de
desfazer à parte (aviso `bound <n> colors to <sistema>`); as outras ficam literais: cores translúcidas e cores de trechos de texto (`text.style`) não são ligadas. O valor vem do arquivo do sistema como está agora, então uma edição ainda não publicada pode casar e ser ligada a essa variável, cujo valor publicado pode ser outro.
Fora do 2D: ligar tipos importados às variáveis e importar para um arquivo de design existente (sempre arquivo novo).

## Ambiente dos agentes

Agentes (Claude, Codex e comandos custom) rodam com o ambiente do shell interativo do usuário: o daemon executa
`$SHELL -ilc` (lê o `.zshrc`, então o `node` do nvm e o `PATH` valem), com timeout de 5 s, e guarda o resultado por
10 min. Quando um rc file (`.zshenv`, `.zprofile`, `.zshrc`, `.bash_profile`, `.bashrc`, `.profile`) muda de data, a
captura é refeita antes do próximo lançamento; ao vencer o TTL, o último resultado bom segue valendo enquanto a nova
captura roda em segundo plano. Se a captura falha, vale o último resultado bom (ou só as chaves do Orq, se nunca houve
um).

- `ORQ_ENV_CAPTURE=1` está definido durante a captura: use-o no `.zshrc` para pular trechos lentos.
- `ORQ_USER_ENV=off` no ambiente do daemon desliga a captura.
- As chaves do Orq vencem as do usuário, e o `orq` fica primeiro no `PATH`. `LANG`, `SSH_AUTH_SOCK` e `TMPDIR` ficam
  com o valor do usuário quando ele tem um.
- O preset Shell não muda: não usa a captura e continua lendo os próprios rc files.

## Ferramentas do Orq no agente

- **MCP `orq`:** cada terminal Claude recebe `--mcp-config` com um servidor `orq` (arquivo 0600 por terminal, sem token:
  o `orq mcp` herda `ORQ_TOKEN` do ambiente do agente). Os MCPs e a configuração global do usuário não são alterados.
  Ferramentas de painel que o terminal não alcança ficam ocultas; as que não dependem de painel (artifacts, arquivos e
  sistemas de design) aparecem sempre. A lista é revista a cada 10 s (`ORQ_MCP_POLL_MS` muda o intervalo) e o cliente
  recebe `tools/list_changed`.
  Sem `--strict-mcp-config`, o Claude Code soma os servidores do `--mcp-config` aos do usuário. Qual vence quando o
  usuário já tem um servidor chamado `orq` na própria configuração não foi verificado (a ajuda do `claude` não diz):
  pode haver conflito. Se tiver um, renomeie o seu.
- **Orientação:** no SessionStart do Claude, e de novo depois de compactação, o agente recebe um texto curto: que está no
  Orq, o nome do terminal e do andar, os peers e só os painéis que ele alcança. O Maestro também aprende
  `orq panel open|close|move` e `orq connect`.
- **Codex:** não tem hook de SessionStart, então não recebe orientação. O MCP `orq` no Codex é opcional e vem desligado:
  com `ORQ_CODEX_MCP=1` no ambiente do daemon, vai por `-c mcp_servers.orq.*` com `env_vars` (só nomes). Essa chave vem
  da doc atual do Codex e não foi verificada contra um `codex` instalado (uma chave desconhecida poderia impedir o Codex
  de abrir).

## Registro de trabalho

O daemon guarda, por terminal, o que o agente está fazendo: um **trabalho** com tarefas, jobs (subagentes e shells em
segundo plano), notas e commits. Os dados ficam em `<raiz>/work/` (`work.json`, 0600, e `work-archive.jsonl`).

**Limites:** 500 tarefas, 200 jobs, 200 notas e 200 commits por trabalho, e os 200 trabalhos fechados mais recentes.
O excedente vai para `work-archive.jsonl`; nada é apagado. Só o "limpar histórico" do app apaga (trabalhos fechados e o arquivo).

**Hooks do Claude Code** (gravados no `--settings` de cada terminal Claude; o Stop, o SessionStart e o UserPromptSubmit já existiam):

| Evento | Matcher | Comando |
|---|---|---|
| `PostToolUse` | `TodoWrite\|Task.*\|Agent\|Bash\|BashOutput\|KillShell` | `orq hook claude-tool` |
| `SubagentStop` | (todos) | `orq hook claude-subagent-stop` |
| `PreCompact` | (todos) | `orq hook claude-precompact` |
| `SessionEnd` | (todos) | `orq hook claude-session-end` |

Todos com timeout de 5 s; o hook nunca falha nem atrasa o agente (erros vão para `~/Library/Logs/Orq/hooks.log`).
Os nomes dos campos dos payloads (`tool_input`, `tool_response`, `agent_id`, `agentId`, `task_id`…) são **suposições, ainda
não verificadas contra payloads reais**; o parser é tolerante, mas confira com um Claude de verdade.

**Estados**
- Tarefa: `open`, `inProgress`, `done`, `deferred` (com motivo), `abandoned`.
- Job: `running`, `finished`, `gone`, `unknown`. `gone` só quando confirmado (o terminal morreu, ou o processo não existe
  mais); sem nenhum sinal por 30 minutos um job `running` vira `unknown`, e um sinal de fim posterior ainda o finaliza.
- Trabalho: ativo ou fechado (por `merge`, `agent:<terminal>` ou `app`); um ativo por terminal.

**Trabalho implícito:** sem trabalho ativo, o primeiro hook com tarefas, título de tarefa ou job abre um trabalho
chamado `"<nome do terminal> — AAAA-MM-DD"`, com o andar e a branch do terminal. `orq work task add` e `orq work note` também abrem um.

**Comandos** (`orq work …`): `start`, `done [--reason]`, `reopen`, `task add|done|defer|drop` (defer/drop pedem o motivo),
`note`, `status [--all]`, `list [--closed]`, `get`. `clear-history` é só do app. Cordas: um terminal vê só o próprio
trabalho; um Maestro vê também o dos terminais ligados por corda a ele (`--terminal`); o app vê tudo. Um terminal fora
do alcance dá o mesmo "não encontrado" de um inexistente.

**Fechamento por merge:** (1) ao `land` de um andar (não no modo `pr`, que ainda não foi integrado); (2) no Stop, quando
há um commit desde que o trabalho abriu e a branch é ancestral do destino (a `baseBranch` do andar, ou a branch do chão).
Um trabalho sem branch nunca fecha sozinho. Os commits novos entram no trabalho a cada Stop.

**Codex e shell** não têm hooks: usam só os comandos explícitos `orq work …`.

## Painel Trabalho

Plug-in **Trabalho** (dock direito; abrir de novo só seleciona a aba existente). Mostra, por trabalho do workspace:
título, terminal · branch, tags de contagem por estado, tarefas e jobs ao clicar, e um ícone de alerta quando há job
`gone`/`unknown` ou aprovação pendente. Abaixo, o chat; os cartões de aprovação ficam acima da lista. O menu "…" de cada
trabalho tem **Recolocar no trilho** e **Fechar…** (fechados ficam recolhidos, com "Reabrir").

**Perguntas de status** (botões "Onde estamos", "O que travou", "O que está rodando"): o daemon responde com o registro,
**sem gastar tokens** e sem tocar no agente (mensagem `orq` em cinza). Só contam frases exatas, sem acento nem maiúsculas
(`onde estamos`, `status`, `como estamos`, `o que travou`, `o que falta`, `o que está rodando`, `rodando`…), com no
máximo palavras de enchimento no fim (`agora`, `ai`, `então`, `por favor`, `pf`, `me diz`, `hoje`). Qualquer outra coisa
pode ser uma instrução e vai ao agente sem alteração.

**Roteamento do chat:** (1) `@nome` (sem diferenciar maiúsculas) manda o resto do texto para esse terminal; (2) sem `@`,
com um trabalho selecionado: o Maestro do trabalho (o próprio terminal, se for Maestro; senão o primeiro Maestro ligado por
corda, em ordem de nome); (3) sem Maestro, o terminal do trabalho; (4) sem `@` e sem trabalho: "Escolha um trabalho ou
comece com @nome.". A mensagem é entregue depois que o agente fica 2 s calado e a resposta volta ao chat (até 30 min).
Chat e `work.chat.*` são só do app; terminais recebem "não autorizado".

**Aprovações.** Duas fontes alimentam a mesma lista de pendências por terminal:
- o **hook `Notification`** do Claude (`orq hook claude-notification`), que o Claude só envia **6 s** depois de abrir o
  diálogo, e só vale com `notification_type = "permission_prompt"`;
- o **padrão na tela**: a pergunta `Do you want to …?` com a opção `1. Yes` até 3 linhas depois (principal, pois não espera
  os 6 s), mais `(y/n)`, `[y/n]` e "press enter to continue".

Aprovar/Negar só escreve no terminal se **o mesmo pedido ainda está na tela** (o texto capturado aparece contíguo nas
últimas 40 linhas) e nenhuma tecla chegou desde então; senão responde "pedido não está mais pendente" e não escreve nada.
Teclas: menu do Claude, aprovar = `1`, negar = Esc; `(y/n)`, `y`/`n` + Enter; "press enter", Enter (negar só dispensa).
Se em 2 s o diálogo não reage (nenhuma saída), a aprovação volta a ficar pendente.
O cartão mostra o texto capturado inteiro; Enter nunca aprova. Aprovação "saída demais para conferir" (`unknown`) **nunca
escreve nada**: só "Entendi, vou olhar o terminal". Enquanto há aprovação pendente, o **chat e o `inject`** (recrutar,
partituras, recolocar no trilho) **não digitam no terminal**. O `orq ask` simples continua podendo responder a um
pedido, por desenho (R7: é como um Maestro responde ao prompt de outro agente).

**Recolocar no trilho:** só a pedido (botão ou `orq work rerail [--terminal]`; Maestros só alcançam terminais ligados por
corda). Injeta no agente um bloco só com o **estado vivo** (tarefas em andamento/abertas, jobs rodando, 5 decisões mais
recentes; ≤ 2000 caracteres, controles e caracteres de formato removidos). Recusado com aprovação pendente ("está pedindo
aprovação; recolocar no trilho depois de responder") e sem trabalho ativo.

**Histórico do chat:** `<raiz>/work/work-chat-<workspaceId>.jsonl` (0600) e `…-archive.jsonl`, dentro de `work/`, portanto
**incluídos no backup**. Passando de **1200** mensagens, as mais antigas vão para o arquivo e ficam as **1000** mais novas.
"Limpar conversa" (`work.chat.clear`) é só do app e move tudo para o arquivo, sem apagar.

**Campos de hook supostos, ainda não verificados com um Claude real:** `notification_type` (igual a `permission_prompt`) e
`message` no stdin do hook `Notification` (sem `notification_type`, vale `message` contendo "needs your permission"), e o
formato do diálogo na tela (pergunta numa linha e `1. Yes` até 3 linhas depois). Verificado apenas por `strings` no binário
do Claude Code 2.1.307, sem executá-lo.

## Resumo do trabalho

Um resumo do que um trabalho fez, montado **só com o registro** (sem modelo, sem tokens), sempre disponível. Quatro seções
(as vazias somem):
- **Feito**: tarefas concluídas, commits e "Mergeado" quando o trabalho fechou por merge.
- **Para depois**: tarefas adiadas (com o motivo) e as decisões anotadas.
- **Em aberto** (trabalho ativo) ou **Não feito** (fechado): tarefas abertas ou em andamento, abandonadas (com o motivo) e
  jobs `gone` ("sumiu") ou `unknown` ("sem sinal").
- **Onde parou**: a tarefa em andamento mais recente; sem ela, a última nota.

Cada seção mostra até 40 itens ("… e mais N" no resto) e o resumo todo cabe em 6000 caracteres. O texto vindo dos agentes
é limpo (uma linha, sem caracteres de controle) e aparece literal, nunca como markdown.

**Como pedir**
- CLI: `orq work summary [--id <trabalho>] [--terminal <nome>] [--natural]`. Sem `--id`, vale o trabalho ativo; `--terminal`
  é para Maestros (terminais ligados por corda); o alcance é o mesmo do `orq work status`. `--natural` pede a reescrita do
  modelo local; a resposta traz o markdown sempre, mais `natural` e, se não houve reescrita, o `reason`.
- Chat do painel Trabalho: a frase exata `resumo` (também `resume` e `o que foi feito`, com as mesmas palavras de enchimento
  das perguntas de status; qualquer outra coisa vai ao agente). Sem trabalho selecionado: "Escolha um trabalho para ver o
  resumo.". Não gasta tokens.
- Painel: botão **Resumo** e a seção Resumo do trabalho selecionado. Com a reescrita do modelo local, o link **Ver dados**
  alterna para o resumo do registro (e **Ver resumo** volta). Sem reescrita, o painel mostra o registro e a linha cinza
  "Resumo sem reescrita: ‹motivo›".

**Modelo local (opcional).** A reescrita em linguagem simples e as perguntas livres usam o FoundationModels da Apple:
precisam do **macOS 26 com Apple Intelligence ligada**. Roda **no aparelho**, sem rede e sem tokens. Em outros sistemas o
Orq funciona igual, só sem essas duas coisas. A reescrita tem **10 s** de prazo e a pergunta **20 s**; passou disso, vale o
resumo do registro (ou uma mensagem de erro no chat). Uma chamada travada é **cancelada**, e o resultado de uma falha fica
guardado por 60 s para não repetir a chamada. A saída do modelo é só texto: controles e caracteres de formato são removidos,
o tamanho é limitado e ela nunca vai a um terminal.

**Perguntas livres: `?` no chat.** Uma mensagem que começa com `?` vai ao assistente local, não ao agente. O assistente só
**lê** o registro, por três ferramentas: listar os trabalhos (ativos e os 20 fechados mais recentes), o resumo de um trabalho e
o status de agora. Não escreve em nada e **nunca chega a um terminal**. Responde uma pergunta por vez e **guarda no máximo
3** na fila; a seguinte recebe "O assistente está ocupado, tente de novo em instantes.". Sem o modelo, a resposta é
imediata: "Perguntas livres precisam do macOS 26 com Apple Intelligence ligada (‹motivo›)."; o campo de texto do painel
mostra o motivo.

**O que vai para a Memória ao fechar.** Quando um trabalho fecha (por merge, agente ou usuário, inclusive quando o terminal
é removido), o resumo do registro (sem reescrita) é guardado na Memória do repositório do terminal como **decisão não
revisada** (origem "Orq (resumo)", assunto `trabalho <id>`), em **texto simples**; aprove ou descarte em `memory.review`.
Reabrir e fechar de novo **substitui** o anterior. Trabalho vazio (sem tarefas, notas nem commits) não é guardado, nem um sem
repositório (fica no log). Uma falha ao guardar vira uma mensagem do Orq no chat; o fechamento não é desfeito.
**Limite documentado:** o controle de "já guardei este fechamento" fica em memória do daemon; depois de reiniciá-lo, o mesmo
fechamento pode ser guardado de novo.

## Backup dos dados

Menu **Arquivo → Exportar dados do Orq…** gera um `.zip` (0600) com `manifest.json` na raiz.

- **Entra:** `design/` (inclui o servidor do Design), `artifacts/`, `memory/`, `workspaces/` (sem o spill de terminais
  em `workspaces/*/terminals`), `work/`, `partituras/` e o workspace padrão (no manifesto).
- **Fica de fora:** `run/`, `hooks/`, `cache/`, `usage/`, `admin.token`, `screens/` e o `.orq/memory` de cada repositório.
- O arquivo guarda os links do Design: **trate como uma senha**.
- A exportação pausa o Design por instantes (os painéis reconectam; o Design responde "backup em andamento" nesse intervalo).
- **Importar** (**Arquivo → Importar dados do Orq…**): valida o arquivo e mostra a contagem (designs, design systems,
  artifacts) sem mexer em nada; pede confirmação de que o serviço vai reiniciar e os terminais abertos vão fechar. O
  import é aplicado no próximo start do serviço; os dados atuais vão para `<raiz>/.replaced-<ms>` (nada é apagado).

## Partituras

Uma partitura é uma equipe pronta: terminais (com preset, papel/prompt inicial e posição), painéis, cordas e, se quiser, um andar.

- **De fábrica:** *Feature fullstack* (Maestro, backend, interface e revisor, com painéis Design e Navegador; pede andar) e
  *Investigar bug* (Maestro, investigador e testes). Não podem ser substituídas nem removidas.
- **Salvar:** menu do canvas ou ⌘K → "Salvar canvas como partitura…" / "Salvar seleção como partitura…". Só entra o estado
  permitido: do Design o arquivo e o armazenamento, do Navegador o endereço http(s) (sem usuário e senha; com
  aviso se tem parâmetros `?…`) e o armazenamento. Painéis de
  dispositivo (e os demais plug-ins) são pulados, com aviso. Nunca vão para o arquivo: histórico de terminal, tokens, links
  do Design, variáveis de ambiente, caminhos absolutos e `cwd`.
- **Aplicar (tudo ou nada):** ⌘K → "Aplicar partitura…", a seção PARTITURAS da barra lateral ou "Aplicar partitura aqui…" no
  canvas. A prévia lista tudo que será criado, com cada comando e cada prompt; **Aplicar** só libera depois de rolar até o fim.
  Se qualquer passo falha (ou um terminal fica parado numa pergunta, como confiar na pasta), o que foi criado é desfeito.
  O desfazer remove só o que esta aplicação criou: terminais e painéis; o andar é removido apenas se não tem commits,
  alterações não commitadas nem arquivos ignorados (build, `.env`) e nenhum terminal ficou nele — senão fica, com aviso.
  Arquivos de design criados também ficam, com aviso. Se o serviço cair durante a aplicação, o que já foi criado fica;
  remova à mão.
- **Onde:** aplicada pelo app, a equipe nasce no andar que está na tela (a pasta padrão é a do andar); se a partitura pede
  andar, um novo é criado e o app vai para ele. Um Maestro aplica sempre no seu próprio andar e na sua pasta.
- **Arquivo `.orqpartitura`:** JSON com `format: 1`, até 256 KiB, 20 terminais e 20 painéis; campos desconhecidos são
  ignorados. Tamanhos de 320×200 a 4000×4000 (painéis a partir de 200×200), posições até 100000. **Exportar…** e **Importar…** estão na folha de partituras. Um arquivo importado não é confiável: a tela de
  confiança mostra cada comando (`preset: custom`) e cada prompt antes de guardar, e importar não cria nada até você aplicar.
  Se já existe uma partitura salva com o mesmo id, a tela oferece **Substituir**. O aplicar envia o resumo (digest) da
  prévia: se a partitura mudou desde então, o daemon recusa.
- **Maestro:** `orq partitura list`; `orq partitura apply <id> --name <nome> [--floor true|false]` (tudo que cria fica
  ligado por corda ao Maestro, com as regras de `floor create` e `panel open`); `orq partitura save <nome> --terminals a,b,c
  [--panels …]`. Remover, importar e exportar são só do app.
- **Backup:** as partituras salvas (`<raiz>/partituras/`) entram no backup dos dados (veja abaixo).

## Notas

- **Andares (floors):** `floor.list` é visível a todo terminal gerenciado (nomes, caminhos e branches de todos os
  andares). Criar é só para Maestros; integrar/excluir, só para o Maestro criador ou o usuário; land `pr`, só o usuário.
- **Painel de uso:** os provedores ficam em `~/Library/Application Support/Orq/usage/providers/*.json` (semeados uma vez). O provedor Claude vem
  desativado: não há fonte local de uso que não envie um prompt. O provedor Codex não foi verificado contra a saída
  real do `codex`.

## Licença

MIT — veja [LICENSE](LICENSE). Componentes de terceiros embutidos no app: `Resources/NOTICE-*`.
