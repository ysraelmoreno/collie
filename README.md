# Collie

Antes chamado Orq.

Daemon (`collied`), CLI (`collie`) e app de canvas (SwiftUI/AppKit) para orquestrar terminais. Swift 6.2, macOS 15.

![Collie: canvas com um Pastor, um simulador iOS e o painel Design](docs/screenshot.png)

## Build

```sh
swift build
swift test
scripts/bundle-app.sh   # gera build/Collie.app (assinado ad hoc)
```

Opcional: rode `scripts/make-signing-cert.sh` uma vez para criar a identidade autoassinada "Collie Local" no keychain de
login (o macOS pede sua senha para confiar nela). Com ela o `bundle-app.sh` assina o app sempre com a mesma identidade e
o macOS (TCC) mantém as permissões de Documentos e Acesso Total ao Disco entre rebuilds; sem ela a assinatura é ad hoc e
as permissões são esquecidas a cada build. No primeiro build o macOS pode pedir acesso do `codesign` à chave; escolha "Sempre Permitir". Outro nome: `COLLIE_SIGN_IDENTITY`.

## Instalar

Copie `build/Collie.app` para `/Applications` **antes do primeiro uso**. O `collied` roda via launchd; se o app estiver em
`~/Documents`, `~/Desktop` ou `~/Downloads`, o daemon trava na permissão de pastas (TCC) do macOS. O app avisa quando
detecta isso.

**Atualizar:** substitua o `Collie.app` em `/Applications`. O serviço (`collied`) continua rodando a versão antiga até ser
reiniciado: o app detecta isso e mostra um aviso com **Reiniciar serviço** (encerra os terminais abertos; nunca
reinicia sozinho). Manualmente: `launchctl kickstart -k gui/$(id -u)/dev.collie.daemon`.

## Vindo do Orq

O Collie é o antigo Orq. Ao abrir o `Collie.app` pela primeira vez, ele leva o que já existe:

- **Dados:** `~/Library/Application Support/Orq` passa a `~/Library/Application Support/Collie` (um único `rename`; nada é
  copiado nem apagado) e `Orq` vira um **symlink** para a pasta nova, porque caminhos absolutos guardados nos dados ainda
  apontam para ele. Mantenha o symlink. Se já existir uma pasta `Collie`, nada é movido e as duas ficam como estão.
- **Serviço:** o app encerra o LaunchAgent `dev.orq.daemon` (e remove o plist dele) e instala o `dev.collie.daemon`. Só
  quando o `Collie.app` roda com o rótulo padrão.
- **Preferências** (tema, estrutura, fonte do terminal, consentimentos) e **URLs salvas** do Navegador passam do domínio
  `dev.orq.app` para o do Collie.
- **Rebanhos:** as antigas partituras (`partituras/*.orqpartitura`) viram rebanhos `herds/*.collieherd`. Se o nome novo já
  existe, o arquivo antigo fica onde está (os dois ficam) e o `collied` registra isso no log a cada início. Um `expect` (digest)
  copiado de uma prévia da época do Orq é recusado uma vez: gere uma prévia nova.
- **Arquivos antigos ainda abrem:** `.orqbackup` (Importar dados), `.orqpartitura` e `.colliepartitura` (Importar rebanho).

**O que fica como estava:** repositórios com `.orq/` continuam usando `.orq/` (memória, cache); os repositórios novos usam
`.collie/`. Cercados antigos em `.orq/floors` ou `.collie/floors` seguem funcionando e se integram (`land`) normalmente; os
novos ficam em `.collie/paddocks` (e, nos repositórios que ainda usam `.orq/`, em `.orq/paddocks/`). As branches `orq/<nome>` continuam com esse nome; as novas são `collie/<nome>`.
Variáveis `ORQ_*` não valem mais: use `COLLIE_*`.
Cookies e logins dos painéis do Navegador ficam nos dados antigos do WebKit (`~/Library/WebKit/dev.orq.app`): será preciso
entrar de novo nos sites; nada é apagado. Páginas que agentes escreveram com links absolutos `orq-artifact://` mantêm esses
links (conteúdo seu não é reescrito); as URLs salvas dos painéis são convertidas.

> **Atenção: depois do upgrade, não abra o `Orq.app` de novo.** O app antigo ainda sabe subir o `orqd` sobre os mesmos
> dados: se você aceitar a tela de consentimento dele, o cão velho solta os terminais do Collie e pode apagar o pasto
> (terminais, coleiras, cercados e painéis). Ao aposentar o agente antigo, o Collie já desliga o consentimento do Orq.app,
> então ele para nessa tela: feche-o e apague-o.

**O que você faz:**

1. **Feche o `Orq.app`** (e qualquer `orqd`) antes de abrir o Collie. Enquanto um `orqd` responde, o `collied` se recusa a
   iniciar.
2. **Abra o `Collie.app`.** O upgrade reinicia o serviço: **os terminais abertos são fechados.**
3. Depois de conferir, apague `/Applications/Orq.app` e não o abra mais (dois serviços sobre os mesmos dados).

**Se algo falhar**
- O app mostra "O Orq antigo ainda está rodando; feche o Orq.app e tente de novo": o agente antigo não parou. Feche o
  Orq.app e abra o Collie de novo.
- Se o `collied` não sobe e não move os dados (ele sai e o launchd tenta de novo), o motivo está em
  `~/Library/Logs/Collie/`, na linha que começa com `collied: legacy Orq data:`.

## Aparência

**Preferências** (⌘,):

- **Tema:** Escuro, Claro ou Sistema (segue Ajustes do macOS > Aparência). Vale para todas as janelas, sem reiniciar.
- **Estrutura:** Compacta (barra de cercados em chips, janela pode ser estreita) ou Completa (barra lateral com cercados e uso).
  Trocar não recarrega painéis nem move nós.
- **Fonte do terminal:** DM Mono, SF Mono ou Menlo, tamanho de 11 a 16. Os terminais abertos reajustam na hora.

**⌘K** abre a paleta de comandos: Novo terminal, Abrir painel…, Novo cercado…, Ir para o Pasto, Ir para o cercado …,
Ajustar à tela, Uso dos agentes e Preferências…. Digite para filtrar, ↑/↓ para escolher, ↩ para executar, Esc para fechar.

**Fontes:** o app usa Space Grotesk (interface) e DM Mono (terminal e código). Baixe-as antes do bundle:

```sh
scripts/fetch-fonts.sh    # vendor/fonts (fixado por SHA-256)
scripts/bundle-app.sh
```

Sem esse passo o bundle sai com um aviso e o app usa as fontes do sistema. As duas famílias são licenciadas sob a
SIL OFL 1.1; o aviso vai em `Collie.app/Contents/Resources/NOTICE-fonts` (fonte: `Resources/NOTICE-fonts`).

## Dispositivos Android

O plug-in **Dispositivo** mostra a tela de um Android no canvas (vídeo do scrcpy, com mouse e teclado) e dá aos agentes
comandos `collie device …` via adb, rodados pelo daemon.

1. Instale o adb: `brew install --cask android-platform-tools`.
2. No aparelho, ative **Opções do desenvolvedor → Depuração USB**, conecte por USB e aceite a chave do Mac (ou use
   um emulador). `adb devices` deve mostrar o aparelho como `device`.
3. Antes do bundle, baixe o servidor do scrcpy (fixado em v3.3.1, conferido por SHA-256):

   ```sh
   scripts/fetch-scrcpy-server.sh   # vendor/scrcpy-server
   scripts/bundle-app.sh            # copia para o Collie.app
   ```

4. No app, **Abrir painel… → Dispositivo**, escolha o aparelho (botão **Atualizar** relê a lista). Ou um Pastor:
   `collie panel open device --serial <serial>` (sem `--serial`: o único aparelho online).

No painel: clique/arraste = toque, rolagem = scroll, teclado com o painel em foco (acentos inclusive); a barra tem
**Voltar**, **Início** e **Recentes**. Sem aparelho, o painel mostra o estado e **Reconectar**.

Comandos (um terminal precisa de uma guia até o painel do canvas; painel na doca vale para todos):

```sh
collie device list                     # aparelhos {serial,state,model,product,panels}
collie device screenshot               # PNG; devolve {path,width,height}
collie device ui                       # árvore de UI com refs (e1, e2, …)
collie device tap 540 1200             # ou: collie device tap --ref e3
collie device swipe 540 1800 540 600
collie device text "ola mundo"
collie device key Back                 # Enter, Home, ... ou um keycode
collie device logcat --lines 100 --grep MyApp
collie device install app.apk
collie device launch com.example.app
```

Limitações: sem áudio; `device.text` só ASCII e não digita `%s` literal (é o
`input text` do Android; acentos e `%s`, digite pelo painel); um ANR não vira evento (só crashes do buffer de crash do logcat).

Emuladores instalados e desligados aparecem em `collie device list` e na folha como `avd:<nome>` (`state: "off"`). Abrir o painel
de um liga o emulador e espera o boot (até 3 min); com `collie panel open device --serial avd:<nome>` é igual. O emulador roda em
sessão própria, então parar ou reiniciar o serviço não o derruba. O Collie nunca o desliga: fechar o painel ou parar o serviço o
deixa ligado. `COLLIE_EMULATOR` aponta um binário `emulator` fora do SDK padrão.

## Simulador iOS

O mesmo plug-in **Dispositivo** mostra um Simulador iOS (vídeo e entrada pelo [AXe](https://github.com/cameroncooke/AXe), comandos
via `simctl`).

1. Xcode 26+ com um runtime iOS instalado (`xcrun simctl list devices` deve listar simuladores).
2. Instale o AXe: `brew install cameroncooke/axe/axe` (testado com o AXe 1.8.0).
3. No app, **Abrir painel… → Dispositivo**: os simuladores aparecem como `iPhone 16e — iOS 26.3`, e os desligados com
   `(desligado)`. Abrir o painel de um simulador desligado o liga (pode levar até ~2 min). Ou um Pastor:
   `collie panel open device --serial <UDID>`.

No painel: clique = toque, arrastar = um swipe ao soltar, rolagem = swipe a partir do centro, teclado com o painel em
foco; a barra tem **Início** e **Bloquear**. Os comandos `collie device …` valem para o simulador, com coordenadas em
**pontos** (não pixels): `collie device list` mostra `platform: "ios"`, o UDID como `serial` e o estado (`booted`, `shutdown`).

Limitações: só simulador (iPhone físico não); `device.text` só digita teclado US (ASCII); sem botões de volume/Siri na
barra; um arrasto vira um único swipe ao soltar (sem seguir o dedo, sem multitoque); o vídeo e a entrada dependem de o AXe
acompanhar o Xcode (ele usa frameworks privados: uma atualização do Xcode pode quebrá-los até sair um AXe novo).

## Navegador (Browser)

O plug-in **Navegador** é um `WKWebView` que os agentes dirigem com `collie browser …` (`snapshot`, `click`, `fill`, `type`,
`key`, `hover`, `resize`, `emulate`, `screenshot`, `storage`, `init-script`…; `--panel <nome>` se houver mais de um).

**Navegadores de teste.** Qualquer terminal, não só o Pastor, abre seus próprios navegadores — só do plug-in Navegador,
até 8 por terminal (`tooMany` além disso):

- `collie panel open browser --url <url>`: **headless** — sem nó no canvas e fora das docas, mas a página roda de verdade
  (animações, timers, entrada confiável, screenshots). Só o terminal que abriu, o app e o Pastor com guia até ele a veem em
  `collie panel list` (`placement: "headless"`). Fecha sozinho quando o terminal é removido ou o processo dele sai, e os
  screenshots dele vão junto.
- `collie panel open browser --url <url> --visible`: um painel normal no canvas, no cercado do terminal.

Nos dois casos o painel já nasce com uma guia até quem abriu. Um terminal que não é Pastor fecha e move só os navegadores
que abriu (e os visíveis ficam no canvas). O Pastor segue como antes e também pode pedir `--placement headless`.

Fluxo típico de QA responsivo, três navegadores em paralelo:

```sh
for w in 360 768 1280; do
  collie panel open browser --name qa-$w --url http://localhost:3000
  collie browser resize --panel qa-$w --width $w --height 800 &
done; wait
collie browser emulate --panel qa-360 --color-scheme dark --reduced-motion reduce
for w in 360 768 1280; do collie browser screenshot --panel qa-$w --full-page --out shots/home-$w.png & done; wait
collie panel close qa-360   # ou deixe: fecham quando o terminal sai
```

`--out` é gravado pelo processo `collie` (relativo ao diretório atual dele); o daemon só escreve em `<raiz>/screens`.

## Design

O plug-in **Design** é o [figcraft](https://github.com/storytold/figcraft) v0.7.0 (fixado, sem a marca ArtCraft e sem
servidor público) embutido: o daemon roda um `figcraft-server` local (só `127.0.0.1`) e o painel mostra a UI web dele ao
vivo; os agentes editam o mesmo arquivo pela CLI, na mesma sessão.

1. Pré-requisito: `rustup` com o alvo wasm (o Rust do Homebrew não serve):
   `brew install rustup && rustup-init -y --no-modify-path && rustup target add wasm32-unknown-unknown`.
2. `scripts/build-figcraft.sh` (gera `vendor/figcraft/{bin,web,licenses}`; a primeira vez leva ~10 min), depois
   `scripts/bundle-app.sh` (copia para `Contents/Resources/figcraft`). Rodando com `swift run`, aponte
   `COLLIE_FIGCRAFT_DIR=$PWD/vendor/figcraft` para o daemon.
3. No app, **Abrir painel… → Design**: escolha um arquivo ou digite um nome em **Novo arquivo…** e clique **Criar**.
   O painel abre o figcraft já dentro da sessão do arquivo, numa aba, sem o diálogo "Entrar" (o link vem só do daemon;
   um link ruim mostra o erro do figcraft). Ou um Pastor: `collie panel open design --file <nome>` (cria se não existir).

Comandos dos agentes (`collie design …`, ligados ao painel por uma guia; `--panel <nome>` se houver mais de um): `files`,
`new <nome>`, `run <comando> --params '{…}'`, `batch --commands '[…]'` (um passo de desfazer, tudo ou nada), `inspect`,
`screenshot`, `export --format html|css|react|figcraft`, `help [busca]`. `export --format figcraft` é recusado num arquivo
que usa design systems (o `.figcraft` levaria os links das bibliotecas): exporte html, css ou react.

O export HTML agora gera um artifact versionado (veja a seção Artifacts).

Limitações: os arquivos ficam no armazenamento do servidor local (não no git; `export --format figcraft` gera um
`.figcraft`); o painel usa WebGPU quando o WebKit tem um adaptador (sonda única por execução, prazo de 2 s) e WebGL2 (`?webgl`) caso contrário; se a página WebGPU não iniciar, recarrega com `?webgl`. `COLLIE_DESIGN_GPU=webgl|webgpu` força um dos dois. Medido em macOS 15 (Darwin 24.6, arm64): a sonda respondeu false nesta máquina; o figcraft registrou o backend Gl com e sem ?webgl. Servidor, CLI e UI são sempre a mesma versão (v0.7.0). Limitações da importação de HTML: veja a seção Importar HTML.

### Onde desenhar

Para trabalho de interface (tela nova, fluxo novo, mudança visível, ou só "faz um design de X"), o Pastor desenha antes
onde a preferência **Onde desenhar** do workspace manda: `artifact` (padrão) numa página na Prévia
(`collie artifact new prototype <nome>`: HTML/CSS com fontes, animação e bibliotecas offline, `collie font add`), `figcraft`
num painel Design (FigCraft), ou `ask`, que pergunta uma vez. Com `artifact`, o FigCraft fica para quando o usuário pede ou
para trabalho de design system. Quem altera é o app (**Preferências → Onde desenhar**) ou um Pastor do pasto, com
`collie design prefer artifact|figcraft|ask`; qualquer terminal lê com `collie design prefer`. Os valores antigos continuam
aceitos e migram sozinhos: `always` vira `figcraft`, `never` vira `artifact` (desconhecido ou ausente: `artifact`). Se já
houver um painel Design ligado ao Pastor, ele é usado primeiro. O rebanho de fábrica **Feature com design** (Pastor,
designer, interface e tester) segue a preferência: com `figcraft` vem com o painel Design e o Navegador ligados; senão o
Pastor abre a página do design com `collie artifact new prototype feature --connect <designer>,<interface>,<tester>`
(`--connect` é só de Pastor) e o tester compara `collie preview screenshot` com o Navegador.

## Diagrama

O plug-in **Diagrama** é um editor leve de fluxogramas, raias, ERD e UML (o [draw.io](https://github.com/jgraph/drawio)
v32.6.1 em modo embed, fixado, offline: nenhuma requisição sai da máquina; `scripts/build-drawio.sh` gera
`vendor/drawio/web`, ~34 MB, sem os ícones de nuvem Azure/Microsoft, e `scripts/bundle-app.sh` o copia para
`Contents/Resources/drawio`). O documento é um arquivo `.drawio` do projeto (padrão `docs/diagrams/<painel>.drawio`;
`collie panel open diagram --file <caminho.drawio>`, sempre dentro do projeto): versionado no git, editado à mão no painel
(salvo a cada mudança) e pelos agentes, e recarregado quando muda no disco. Comandos (`collie diagram …`): `get`,
`set --xml X | --from ARQ` (recusado se o usuário editou nos últimos 2 s), `mermaid "<texto>" [--page NOME]` (vira formas
editáveis, abaixo do que já existe), `export --format png|svg [--page NOME] [--out ARQ]` e `screenshot [--out ARQ]`.
Avisos de licença: `Resources/NOTICE-drawio` (Apache-2.0; draw.io e diagrams.net são marcas da JGraph).

## Plug-ins externos

Painéis e comandos de terceiros, sem recompilar o Collie (fase 1: só interface web). Um plug-in é uma pasta com
`collie-plugin.json` e `ui/`; só o usuário instala, em **Preferências → Plug-ins → Instalar…** (ou `collie plugin install
--path <pasta>` fora de um terminal; `--replace` para substituir um já instalado), vendo antes os comandos e o que ele substitui. A cópia instalada fica somente leitura
em `<raiz>/plugins/<id>/<versão>/` e é conferida por hash a cada início do serviço. O painel abre como os do Collie (paleta,
`collie panel open <id>`, rebanhos) sem rede nem acesso ao projeto, e os comandos `collie <id> <cmd>` chegam aos agentes
ligados a um painel dele pela guia. Exemplo: `Examples/plugins/notas`. Referência: [docs/plugins/api-v1.md](docs/plugins/api-v1.md).

## Design systems

Um **design system** é um arquivo de design (figcraft) com variáveis (tokens, com modos), estilos e componentes, publicado em
versões. Um deles pode ser o **ativo** do workspace (o padrão de todos os cercados) e cada cercado pode ter o seu. Ao trocar o
ativo, os arquivos de design daquele escopo passam a usar a biblioteca do novo, e os agentes recebem os tokens por
`collie design system tokens`.

No app: **Abrir painel… → Design Systems**. Escreva o **motivo** (obrigatório em toda alteração) e use:
**Novo design system…** (do zero ou a partir de outro), **Usar neste escopo** (Workspace ou um cercado), **Desfazer troca**,
**Publicar versão** e, no **Histórico**, **Voltar para esta versão**. Depois de cada ação o painel mostra o resultado por
arquivo e o que ficou **sem par** (`unmatched`). Se a publicação for recusada porque o sistema "voltou" e o arquivo ainda
mostra o conteúdo mais novo, o painel mostra a mensagem e oferece **Publicar mesmo assim** (com confirmação).
O painel atualiza ao abrir, depois de cada ação e quando o evento `designsystem.changed` chega (no máximo uma vez a cada 500 ms).

Comandos (`collie design system …`): `list`, `history <nome>`, `create <nome> [--from <outro>] --reason`,
`publish <nome> --reason [--force]`, `use <nome> [--paddock <cercado>] --reason` (ou `--none`), `undo [--paddock <cercado>] --reason`,
`revert <nome> --to <versão> --reason`. Para os agentes trabalharem com o sistema ativo do arquivo do painel:
`tokens`, `bind --variable <nome> --field <campo> --ids …`, `style --style <nome> --ids …`, `place --component <nome>`,
`mode --mode <Light|Dark> [--collection <coleção>]` (padrão: `Tokens`, a coleção do sistema inicial).

`undo` alterna entre os dois últimos sistemas do escopo (um segundo `undo` volta ao de antes); para um mais antigo, use o
**Histórico** do painel (ou `use`). `create` não precisa de guia (`--from` copia o arquivo, e a biblioteca da cópia leva o
nome novo). Se um `create` falhou no meio, repeti-lo adota o arquivo deixado; um arquivo adotado cuja biblioteca já saiu
sem mudanças é recusado com "no changes to publish": edite-o e crie de novo.

Quem pode trocar: no workspace, o usuário no app ou um Pastor no pasto (um Pastor num cercado usa `--paddock`); no cercado, o
usuário, o Pastor que o criou ou um Pastor que está num cercado criado pelo usuário. `publish` e `revert` por um terminal
exigem uma guia com o painel Design do sistema. Cada alteração vira uma decisão na Memória: as do workspace e de
`publish`/`revert` na memória global, as de um cercado no repositório do cercado (a mais nova substitui a anterior, venha de quem
vier). Excluir um cercado com sistema próprio aplica o do workspace aos arquivos dele e registra a decisão.

Limitações: a troca casa por nome (variáveis por coleção+nome+tipo, estilos por nome+tipo, componentes e variantes por
nome); o que não casa continua no design system anterior e aparece em `unmatched`. A UI web do figcraft não opera
bibliotecas: troque/publique/volte pelo painel ou pelos comandos. "Voltar" cria uma versão nova e marca o sistema: antes da
próxima publicação é preciso editar o arquivo de volta ou usar `--force`. A troca entre arquivos não é transacional (uma
falha não desfaz os outros; o resultado vem por arquivo).

## Artifacts

Um **artifact** é uma página HTML guardada em versões. Todo `collie design export --format html [--node <id>]` vira um: o
export passa por um pós-processador (`h1`/`section`/`ul`/`a`, reset de CSS, tokens das variáveis com os modos Light/Dark em
`[data-theme]`, grid, SVG inline, layout responsivo básico) e é gravado em `<raiz>/artifacts/<id>/v<N>/index.html`, com
miniatura. Exportar de novo o mesmo (arquivo, nó) — ou, sem `--node`, a mesma página do arquivo (cada página tem o
seu artifact) — cria a versão seguinte do mesmo artifact. Qualquer terminal também pode
registrar uma página que ele mesmo fez (`artifact.add`): fica em `<raiz>/artifacts/<id>/source.html` (com `--root`, a
pasta em `<raiz>/artifacts/<id>/source/…`), somente leitura, e é importada como tela (veja Importar HTML).

No app: **Abrir painel… → Artifacts** (miniatura, origem, versão, status `current`/`stale`/`missing`/`unknown`/`pending`).
**Abrir no Navegador** carrega `collie-artifact://app/<id>/v<N>/index.html`; **Reexportar** gera a versão nova (marca
**desatualizado** quando o design mudou depois do export); **Remover** move a pasta para `artifacts/.removed`.

Comandos (`artifact.*`): `list`, `get <id>`, `add <caminho.html|pasta|.zip> [--root <pasta>] [--title] [--width <px>] [--source <link>]` (o caminho é
resolvido contra o cwd e caminhos absolutos são aceitos; `.html`/`.htm`, sem symlink, até 8 MB), `import <id> [--width <px>]`
(largura 320–3840, padrão 1440), `libs` (veja Bibliotecas offline), `reexport <id>` e `remove <id>` (só o app).

O painel também atualiza sozinho com os eventos `artifact.*` (no máximo uma vez a cada 500 ms); falha de importação em segundo plano chega como `artifact.imported` com `error`.

### Pastas

Cada artifact pode ficar numa **pasta** do usuário: um caminho de até 3 níveis separados por `/` (`Cliente/Landing/v2`),
cada nome com 1–40 caracteres, sem caracteres de controle; a grafia é mantida e a comparação ignora maiúsculas. Sem
pasta, o artifact aparece em **Sem pasta**. A pasta fica no registro do artifact (`artifacts.json`); as pastas criadas pelo
usuário (vazias inclusive), com ordem, cor, fixação e apresentação, ficam em `<raiz>/artifacts/folders.json`.

- `artifact add … --folder <caminho>` e `artifact new … --folder <caminho>` (a Prévia guarda a pasta e o **Salvar como
  artifact** usa). Padrão de um agente: o nome do seu lote, se estiver em um; senão nenhuma (`--folder` explícito vence).
- `artifact move <id> --folder <caminho|"">`: o agente só move os artifacts que ele adicionou; o app move qualquer um.
- `artifact folders`: as pastas (as do usuário na ordem dele, depois as outras) com `count`, `total` e `items`.
- Só o app: `artifact folder create <caminho>`, `folder rename <caminho> <novo>` (move tudo dentro, de uma vez),
  `folder remove <caminho> [--move-to <caminho|"">]` (só vazia, ou levando os artifacts; nunca apaga artifacts) e
  `folder set <caminho> [--color #RRGGBB] [--pin true|false] [--present true|false] [--order <ids>]`.

No painel Artifacts as pastas são uma árvore recolhível com contagem (fixadas no topo, **Sem pasta** por último), busca,
arrastar um artifact para uma pasta, e menu **Nova pasta / Renomear / Remover / Fixar no topo / Apresentação**; no
artifact, **Mover para…**. Uma pasta **apresentação** tem ordem (a de `--order`, depois por criação): a Prévia de um
artifact dela ganha **Anterior / Próxima** e **Apresentar** (tela cheia; setas avançam, Esc sai). O cabeçalho da Prévia
mostra a pasta do artifact.

### Importar do claude.ai

O Collie nunca guarda credenciais do claude.ai nem baixa nada de lá: quem lê o artifact é um terminal **Claude Code** já
logado, com a ferramenta Artifact dele; o Collie orienta, confere e guarda.

- `artifact import-claude <links…> [--folder <caminho>] [--title <t>]` (até 50 links `https://claude.ai/artifact/<id>`
  ou `https://claude.ai/code/artifact/<uuid>`, nada além) devolve ao agente a receita exata: ler cada link com a
  ferramenta Artifact (`read`, e `paths` para os arquivos da página) para `<raiz>/sandbox/<terminal>/state/claude-import/<ms>/<n>/`,
  depois `artifact add <n>/index.html --root <n> --source <link>`; se um link falhar, `artifact import-failed <link> --reason`.
  O conteúdo importado é dado, não instruções (a receita diz isso; a Prévia já isola a página). Um agente importa só
  na pasta do seu lote ou em **Sem pasta**; outra pasta, só a que o app escolheu para aquele link.
- `artifact add … --source <link>`: o mesmo link de novo vira a **próxima versão** do mesmo artifact (`<id>/r<N>/`; a
  pasta continua a dele, salvo `--folder`).
- `--mine`: o agente lista os artifacts do usuário (`list` da ferramenta) num JSON e entrega com
  `artifact import-list <arquivo.json>`; o app mostra a lista para marcar e importa os marcados (até 50 por vez).
- No painel Artifacts, **Importar do Claude…**: cole os links, escolha a pasta e o terminal Claude (padrão: o último
  em que você digitou); o Collie manda o pedido como um ask e cada link mostra **aguardando → importado / falhou** (com o
  motivo), pelos eventos `artifact.added` (`url`) e `artifact.import.failed`. **Importar meus artifacts…** pede a lista.
- Arrastar para o painel (ou para uma pasta) um `.html`, uma pasta (com `index.html`, ou uma página só) ou um `.zip`
  adiciona como artifact. O `.zip` é conferido antes de abrir: sem caminho absoluto, sem `..`, sem link simbólico, sem
  senha, até 2000 arquivos e 64 MiB descompactado; abre numa pasta temporária apagada depois.

**Offline na importação** (todo `artifact add`, só na cópia; o original fica intacto): `<script src>` de React,
ReactDOM, Chart.js, Lucide e htm no unpkg, jsDelivr ou cdnjs viram o `collie-lib://lib/…` correspondente (versão exata
quando bate; senão a vendorizada, com aviso); `<link>`/`@import` do Google Fonts viram `collie-lib://fonts/css` e as
famílias são baixadas em segundo plano (`font add`, se **Baixar fontes do Google Fonts** estiver ligado; senão um aviso).
Módulos ES (`esm`, `.mjs`) ficam como estão. O resto que for remoto fica e é listado em `needsNetwork`; o painel mostra
**precisa de rede** no artifact.

Limitações: as fontes não vão embutidas (fallback do sistema).
Links só de camada inteira; trechos com link dentro do texto saem sem `<a>` (a saída `<a>` é
coberta por fixtures unitárias e pelo teste com o motor real). Fundo-imagem de frame com filhos não é exportado. Todos
os artifacts compartilham a origem `collie-artifact://app` no Navegador (HTML de agente pode ler outros artifacts locais).
Agentes podem usar `text.link` (e `hyperlink` em `text.style`/`node.set`) com http(s), mailto, tel, `#âncora` ou caminho relativo; outros esquemas (`javascript:`, `data:`) são recusados. Não podem usar `image.place` com caminho em `design run/batch`.

### Bibliotecas offline

As páginas locais do Collie não acessam a rede (nem CDN). Para isso o app traz, fixadas por versão e SHA-256, React 18.3.1 +
ReactDOM 18.3.1 (UMD), htm 3.1.1, Chart.js 4.4.9 e Lucide 0.469.0, servidas em
`collie-lib://lib/<nome>@<versão>/<arquivo>` às páginas de artifact (`collie-artifact://`) no Navegador, à Prévia e à
importação de HTML; nunca a sites http(s). `collie artifact libs` lista `{name, version, global, url, licence}`. A versão vai
na URL: atualizar uma biblioteca não muda uma página antiga.

```html
<div id="root"></div>
<script src="collie-lib://lib/react@18.3.1/react.production.min.js"></script>
<script src="collie-lib://lib/react-dom@18.3.1/react-dom.production.min.js"></script>
<script src="collie-lib://lib/htm@3.1.1/htm.umd.js"></script>
<script>
  const html = htm.bind(React.createElement);
  ReactDOM.createRoot(document.getElementById("root")).render(html`<h1>Olá</h1>`);
</script>
```

Sem JSX (não há Babel na página): use `htm`. Em build de desenvolvimento rode antes `scripts/fetch-weblibs.sh` (baixa só
os tarballs do npm, confere o SHA-256 e copia o arquivo UMD + licença para `vendor/weblibs/`); sem ele, `artifact libs`
responde "Bibliotecas offline ausentes" e `scripts/bundle-app.sh` para com erro (`COLLIE_ALLOW_NO_WEBLIBS=1` empacota
sem elas). Licenças: `NOTICE-weblibs` e o `LICENSE` de cada biblioteca em
`Contents/Resources/weblibs/<nome>@<versão>/`.

### Fontes

As páginas usam fontes offline em `collie-lib://fonts`: `<link rel="stylesheet" href="collie-lib://fonts/css?family=Inter:400,700&family=DM%20Mono">`
devolve as regras `@font-face` (sem `:pesos`, todos os que houver) e cada arquivo sai de
`collie-lib://fonts/<família>/<arquivo>`. Vêm com o Collie a Space Grotesk e a DM Mono (`vendor/fonts`); as páginas de
`artifact new` usam as fontes do design system ativo (variáveis de texto com `font` no nome; `mono`/`code`: a monoespaçada),
senão essas duas, e avisam quando uma fonte do design system não foi baixada.

Do Google Fonts: `collie font add "<Família>" [--weights 400,700] [--italic]` (agentes e o app) baixa a família uma vez;
`collie font list` lista as baixadas e as que vêm com o Collie; remover é só no app (**Preferências → Fontes**). Quem baixa é
o daemon, nunca uma página: a API css2 em `fonts.googleapis.com` e os woff2 em `fonts.gstatic.com`, só https, sem
redirecionar para fora desses hosts, até 2 MiB por arquivo e 20 MiB por família, nome em `[A-Za-z0-9 ]{1,64}`. Ficam em
`<root>/fonts/<família>/` (pasta 0700, arquivos 0600) com `font.json` e um `LICENSE.txt` que registra a URL de origem e a
licença (SIL OFL 1.1 ou Apache 2.0, conforme a família; o texto completo fica na página da família no Google Fonts).
**Privacidade:** só o nome da fonte e o download vão ao Google; as páginas continuam offline. A preferência **Baixar fontes
do Google Fonts** (ligada por padrão; só o app muda, `admin.fonts`) desligada faz `font add` recusar com um aviso.

O FigCraft também usa as fontes baixadas: além dos woff2 das páginas, `font add` guarda um TTF inteiro por face em
`<família>/ttf/` (o mesmo css2 pedido com um User-Agent que recebe TrueType; mesmos hosts e limites; se o TTF falhar, a
família fica só para as páginas e o comando avisa). O painel Design entrega esses TTFs ao editor quando ele abre e a cada
`font add`/remoção (patch `0005-runtime-fonts`: `collie_add_font` no build web); os `figcraft-cli` do daemon (exports,
miniaturas) leem `<root>/fonts` por `FIGCRAFT_EXTRA_FONTS_DIR`. Famílias baixadas antes ganham os TTFs no próximo
`font add` delas. É local: quem abre o arquivo sem a fonte vê Inter no lugar.

## Prévia e modelos

A **Prévia** (plug-in `preview`) mostra ao vivo uma página HTML do projeto: `collie panel open preview --file <página.html>`
(sempre dentro do projeto do terminal; qualquer terminal pode abrir até 8, no canvas, ligadas a ele). Quando a página — ou
outro arquivo da pasta dela — muda no disco, ela recarrega em menos de 1 s mantendo a rolagem; se o arquivo some, aparece
**Arquivo removido** sobre o último render. Mudanças feitas no lugar em arquivos de subpastas não são vistas: use
**Recarregar**. O cabeçalho tem **Recarregar** e `Página | Claro | Escuro` (põe `data-theme` no `<html>` da página).
`--artifact <id>` mostra um artifact (somente leitura). A página só lê arquivos da própria pasta do projeto, sem links
simbólicos para fora e sem caminhos com ponto (`.env`, `.git/`, `.collie/`), até 8 MB cada; a rede fica bloqueada
(http/https/ws, WebRTC). Comandos: `collie preview get` (`{file, url, errors}`: os últimos 20 erros da página) e
`collie preview screenshot [--full-page] [--out ARQ]`.

`collie artifact new deck|dashboard|doc|prototype [nome] [--title T]` escreve uma página inicial em
`docs/pages/<nome>/index.html` (nome em `a-z0-9-`, até 48; padrão `<tipo>-<n>`; nunca sobrescreve) e abre uma Prévia nela.
Os tokens vêm do design system ativo (Light/Dark em `[data-theme]`); sem design system ativo, ou com o motor de design
indisponível, a página usa os tokens padrão e `warnings` avisa. As páginas são HTML/CSS/JS que só carregam as
bibliotecas offline (`collie-lib://`): ícones Lucide em todas, Chart.js no `dashboard`, React + htm no `prototype`; sem
elas (ou com `scripts/fetch-weblibs.sh` não rodado, aviso `bibliotecas offline ausentes`) a página funciona do mesmo jeito,
com a nota "Bibliotecas offline indisponíveis". `deck`: slides 16:9 (←/→/espaço); `dashboard`: indicadores, gráfico SVG de um array `data` e tabela;
`doc`: documento com sumário fixo; `prototype`: casca de app de celular com lista, abas e uma folha.

## Comentários

Na Prévia (uma página do projeto ou um artifact) você fixa um comentário num ponto ou elemento da página. Quem recebe é
o terminal dono da página: o que abriu a Prévia; se ele não existe mais, o único terminal ligado a ela por guia; senão
ninguém (ligue um terminal para entregar). O destinatário é fixado ao criar.

No cabeçalho da Prévia, **Comentários (n)** abre a gaveta: **Fixar comentário**, clique no ponto da página, escreva e
**Enviar**. Cada conversa mostra as mensagens (você e o terminal), **Responder**, **Resolver**/**Reabrir** e o filtro
**Abertos | Todos**. Os marcadores numerados ficam sobre a página num mundo isolado (a página não os vê nem os aciona);
se o elemento sumiu, o marcador fica no ponto guardado com "posição aproximada".

- **Entrega.** Suas mensagens ainda não entregues entram no próximo prompt do terminal, uma vez (também depois de
  reiniciar o serviço), cercadas e marcadas como dados, não ordens; cada uma em uma linha, o texto cortado em 1200
  bytes. Funciona fora de lotes. O resto do texto fica em `collie comment list`.
- **Responder.** O agente responde com `collie comment reply <id> "<resposta>"` (só aos comentários endereçados a ele);
  a resposta aparece na conversa da Prévia. `collie comment list [--open]` mostra os comentários dele com as conversas.
  O Codex não tem o gancho do prompt: lê com `collie comment list`.
- **Só você** cria comentários, manda continuações e resolve/reabre (o app); um agente nunca cria nem resolve um.
- **Onde fica.** Nos dados do Collie (`<raiz>/comments/<chave>.json`, 0600), nunca no projeto: nada vai para o git e um
  agente em sandbox não consegue forjar um comentário seu. Entra no backup dos dados.
- Limites: 2000 caracteres por mensagem sua, 4000 por resposta, 500 comentários por página, 200 mensagens por conversa.

## Importar HTML

Uma página registrada por um agente vira uma **tela editável**: `collie artifact add <página.html> [--root <pasta>] [--title]`
guarda a página e começa a importação em segundo plano (status `importing`). Com `--root`, a pasta inteira (css, js,
imagens, fontes; até 2000 arquivos e 64 MiB, sem links) é arquivada em `<raiz>/artifacts/<id>/source/` e a página precisa
estar dentro dela. O app abre a página num WKWebView invisível (JS da página ligado, largura 1440 por padrão), lê o DOM e
os estilos calculados e o daemon transforma isso em comandos figcraft num único `batch` (um passo de desfazer): um
arquivo de design novo (nome = título), com o design system do cercado habilitado, e uma tela com frames (flex/grid viram
auto layout/grid), textos com estilos por trecho, imagens e SVGs. A tela é exportada de volta para o próprio artifact,
que vira `current`; a página original continua como origem.

No painel Artifacts: **importando…**, **falha na importação** (o motivo no balão do status) e **atual**; **Abrir origem**
abre a página original no Navegador para comparar; **Importar de novo** (quando falhou) e **Importar** (quando ficou
`pending`, p. ex. uma página do 2C ou uma importação cortada por reinício do daemon) importam com o app aberto.
Por um terminal: `collie artifact import <id> [--width 390]` (ou já no `add --width 390`).

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
captura roda em segundo plano. Se a captura falha, vale o último resultado bom (ou só as chaves do Collie, se nunca houve
um).

- `COLLIE_ENV_CAPTURE=1` está definido durante a captura: use-o no `.zshrc` para pular trechos lentos.
- `COLLIE_USER_ENV=off` no ambiente do daemon desliga a captura.
- As chaves do Collie vencem as do usuário, e o `collie` fica primeiro no `PATH`. `LANG`, `SSH_AUTH_SOCK` e `TMPDIR` ficam
  com o valor do usuário quando ele tem um.
- O preset Shell não muda: não usa a captura e continua lendo os próprios rc files.

**Admin = o app.** Cada agente usa só o token do próprio terminal (`COLLIE_TOKEN`). O token de admin (`admin.token`)
sozinho não basta: o `collied` de dentro do Collie.app (assinado) só aceita admin do próprio app, conferindo a assinatura
do processo que conecta (cdhash igual ao de `Contents/MacOS/Collie`). Assim o `collie admin …` (e `paddock`/`memory`/
`work`/`lot` sem `COLLIE_TOKEN`) num Terminal comum recebe "admin commands are only accepted from the Collie app: use the
app (comandos de admin só pelo app Collie)". Fora de um `.app` assinado (`swift run`, testes) essa checagem fica
desligada, exceto na raiz padrão (comparada pelo caminho real, links incluídos), onde todo admin é recusado. Depois de
atualizar o app no lugar, a instância antiga ainda aberta é recusada até ser reaberta. Além disso, o daemon recusa o token
de admin vindo de dentro de um terminal do Collie (da sessão Unix do terminal ou descendente dele) e de processos que ele
roda (hooks git, provedores de uso); um processo que não consegue identificar também é recusado. Dentro de um terminal, o
`collie` nem lê o arquivo. Limite: isso não isola processos do mesmo usuário: um agente que consiga parar e reiniciar o
daemon (ou rodar outro daemon sobre os mesmos dados, por exemplo o `collied` verdadeiro copiado num bundle falso) obtém
admin. O sandbox dos terminais (veja a seção abaixo) estreita isso, mas deixa saídas abertas (`osascript`, `launchctl`/`open`
bloqueados só pelo caminho, Keychain acessível): um agente decidido ainda consegue admin por elas. Isolamento de verdade exige os agentes sob outro usuário do macOS.

## Ferramentas do Collie no agente

- **MCP `collie`:** cada terminal Claude recebe `--mcp-config` com um servidor `collie` (arquivo 0600 por terminal, sem token:
  o `collie mcp` herda `COLLIE_TOKEN` do ambiente do agente). Os MCPs e a configuração global do usuário não são alterados.
  Ferramentas de painel que o terminal não alcança ficam ocultas; as que não dependem de painel (artifacts, arquivos e
  sistemas de design) aparecem sempre. A lista é revista a cada 10 s (`COLLIE_MCP_POLL_MS` muda o intervalo) e o cliente
  recebe `tools/list_changed`.
  Sem `--strict-mcp-config`, o Claude Code soma os servidores do `--mcp-config` aos do usuário. Qual vence quando o
  usuário já tem um servidor chamado `collie` na própria configuração não foi verificado (a ajuda do `claude` não diz):
  pode haver conflito. Se tiver um, renomeie o seu.
- **Orientação:** no SessionStart do Claude, e de novo depois de compactação, o agente recebe um texto curto: que está no
  Collie, o nome do terminal e do cercado, os peers e só os painéis que ele alcança. O Pastor também aprende
  `collie panel open|close|move` e `collie leash`. Todo agente aprende `collie access request` e `collie open` e que um
  acesso bloqueado mostra um cartão ao usuário: peça, não contorne.
- **Codex:** não tem hook de SessionStart, então não recebe orientação. O MCP `collie` no Codex é opcional e vem desligado:
  com `COLLIE_CODEX_MCP=1` no ambiente do daemon, vai por `-c mcp_servers.collie.*` com `env_vars` (só nomes). Essa chave vem
  da doc atual do Codex e não foi verificada contra um `codex` instalado (uma chave desconhecida poderia impedir o Codex
  de abrir).

## Sandbox dos terminais

Todo terminal do Collie (agentes e shells) roda dentro de um sandbox do macOS (Seatbelt, `sandbox-exec`): um perfil por
terminal, gerado pelo daemon, que cobre a árvore inteira de processos. Ele é uma fronteira de arquivos, **não** de rede
(a rede continua aberta) e **não** protege você do que roda fora dele (um terminal livre, o Terminal.app, as suas
ferramentas). O Seatbelt é uma API que a Apple marca como obsoleta mas que ainda é distribuída (é a que o Claude Code e o
Codex usam); se um dia sair do macOS, o sandbox para de funcionar e o Collie terá de trocar de mecanismo.

**Modo do sandbox: aberto (padrão) ou estrito.** Em Preferências, "Modo do sandbox" escolhe entre **Aberto (padrão)** e
**Estrito**; a mudança vale para terminais abertos depois (os que já rodam ficam com o modo com que começaram, até
reiniciarem). Só o app muda o modo (`admin.sandbox`, nunca de dentro de um terminal).

- **Aberto (padrão).** O agente lê e escreve tudo na sua conta: chaves e tokens (`~/.ssh`, `~/.aws`, `~/.netrc`, perfis
  de navegador…), qualquer pasta, outros repositórios, os rc do shell, `.git/hooks` e `.git/config`, a configuração
  global dos agentes. Não há cartões de acesso nem limite de projeto para `summon --cwd`, rebanhos e cercados (qualquer
  pasta existente). **O risco, em palavras simples:** um agente (ou um texto malicioso que ele leia, o *prompt injection*)
  pode ler as suas chaves e tokens e gravar ou apagar qualquer coisa na sua conta. **E o que o agente gravar e você (ou
  um terminal livre) executar depois roda sem sandbox:** um rc do shell, um LaunchAgent, um binário no `PATH` (`claude`
  em `~/.local/bin`, o Homebrew), um hook ou config do git. Isso alcança tudo, o Collie incluído; o fechamento abaixo vale
  só para o acesso direto do agente. Continua fechado só o que é do Collie:
  a pasta de dados e o `admin.token` (nem leitura nem escrita, menos os arquivos que o Collie gera para o próprio
  terminal), o app `Collie.app` e os LaunchAgents `dev.collie.*` (só escrita), as pastas que os contêm (não podem ser
  renomeadas), sinais para processos fora do sandbox (não dá `kill` no daemon nem no app), `launchctl` e `/usr/bin/open`
  (só pelo caminho; o `open` vira `collie open`) e o socket do daemon (só o `collie`, com o token do terminal). O git e o
  `gh` que o Collie roda a pedido de um terminal aberto rodam no sandbox desse terminal, e nenhum git do Collie roda hooks.
  O modo vale para o Collie inteiro, e cada terminal guarda o modo com que começou (perfil, cartões, limites de `--cwd`). Os atalhos de `swift`/`xcodebuild` e o sandbox interno dos agentes desligado
  continuam (o Seatbelt não aninha). Um bloqueio dos internos do Collie não vira cartão (fica só contado), e
  `collie access request` responde que o acesso já está liberado.
- **Estrito.** O de sempre, descrito abaixo: escrita só no projeto, segredos fechados, cartões para liberar.

**O que fica fechado (modo estrito)**

- **Escrita fora do projeto.** O terminal escreve só na pasta do projeto (o primeiro ancestral do diretório com `.git`,
  procurado sem rodar o git e nunca acima do seu `$HOME`; num cercado, a worktree do cercado) e nas pastas de trabalho
  das ferramentas (temporários, caches de build e de pacotes, estado do próprio agente). **Se a pasta do terminal for
  o próprio `~`, o projeto é toda a sua pasta pessoal** (a folha de novo terminal avisa): o agente lê e altera tudo nela,
  menos os segredos e o que nunca é gravável (abaixo).
- **Nunca gravável, qualquer que seja o projeto ou o liberado.** Os rc do shell (`.zshrc`, `.zprofile`, `.bashrc`…),
  `~/.gitconfig` e `~/.config/git`, `~/.config/gh` (legível, veja os riscos), `~/.npmrc`/`.yarnrc`, `~/Library/Preferences`, `~/Library/LaunchAgents`,
  `~/Applications`, o app do Collie e a pasta de dados dele. Isso vale também para um projeto dentro delas.
- **Configuração global dos agentes** (`~/.claude`, `~/.codex`, `~/.cursor`, menos as pastas de estado deles e o
  `~/.claude.json`) fica só leitura mesmo com o projeto em `~` ou dentro dela; uma escrita ali gera o cartão normal, e
  só o seu clique em Liberar a abre.
- **Leitura: livre, menos o que nunca é liberado.** O terminal lê qualquer arquivo fora do projeto (documentos, outros
  repositórios, o resto do `$HOME`), menos os segredos, os perfis de navegador, `~/Library/{Mail,Messages,Containers,Group
  Containers}` e a pasta de dados do Collie (só os arquivos que ele gera para o próprio terminal são legíveis). Nenhum
  clique abre esses; um bloqueio de leitura nunca vira cartão.
- **Segredos (nem leitura nem escrita).** Chaves de `~/.ssh`, `~/.aws`, `~/.netrc`, `~/.git-credentials`, `~/.pypirc`, `~/.docker/config.json`, `~/.gnupg`
  (assinar commits com gpg deixa de funcionar; assinatura por ssh com o agente funciona) e os perfis de navegador (Chrome
  e toda a pasta `Google`, Chromium, Edge, Brave, Vivaldi, Arc, Opera, Firefox/Mozilla, Safari, Cookies). O git por SSH
  continua funcionando pelo ssh-agent (`SSH_AUTH_SOCK`), sem ler as chaves. `~/.npmrc` segue legível (pode ter token de registry).
- **Internos do Collie.** O app (o bundle `Collie.app` inteiro), o daemon, o LaunchAgent, a pasta de dados e o `admin.token` não são escritos nem lidos.
  O agente fala com o Collie só pelo `collie`, com o token do próprio terminal.
- **Configuração global dos agentes, só leitura** (`~/.claude/settings.json`, hooks, skills, comandos, plugins,
  `CLAUDE.md`, `~/.codex/config.toml`…), com a exceção do `~/.claude.json` (veja os riscos). `~/.claude/shell-snapshots` e
  `~/.claude/session-env` também são só leitura (o Claude pode avisar que não salvou o snapshot do shell). As pastas de
  estado do agente aceitam escrita nos itens de dentro, mas a pasta em si não pode ser renomeada nem trocada.
- **`.git` aninhado.** Nenhum `.git` (pasta, arquivo ou link) pode ser escrito em subpastas do projeto: o seu git e a sua
  IDE, fora do sandbox, rodariam a configuração dele. Para clonar, clone em `/tmp`. Exceção: `.build/` e
  `Carthage/Checkouts/` na raiz do projeto, onde o SwiftPM e o Carthage baixam dependências.
- **Hooks e config do git.** `.git/hooks`, `.git/config`, `.git/info/attributes` e `commondir` não são escritos (um
  `core.hooksPath` ou `core.fsmonitor` plantado rodaria no seu git). Commit, branch e as demais operações normais funcionam.
- **Sinais.** O terminal só sinaliza processos do próprio sandbox: não dá `kill` no daemon nem no app. `launchctl` e `open` são bloqueados (veja abaixo).

**O que continua aberto, e por quê (riscos aceitos)**

Quem decidiu cada um foi você; nenhum é uma fronteira. Um agente mal-intencionado de propósito consegue rodar código fora do sandbox por qualquer um deles.

- **`osascript` / Apple Events e o socket do Docker** seguem abertos: fazem parte de fluxos reais (automação, containers).
  Um agente pode, por eles, pedir a outros apps que façam o que o sandbox nega.
- **Keychain.** O `/usr/bin/security` roda e `~/Library/Keychains` é gravável, para o Claude manter o login e renovar tokens.
  Qualquer agente pode ler, sem aviso, itens guardados pela CLI `security` (gh e parecidos).
- **`~/.config/gh` é legível** (não gravável): o `git push` por HTTPS usa o `gh` como credential helper. Qualquer agente
  pode usar o seu login do GitHub, como no Keychain acima.
- **`~/.claude.json` é gravável** (o Claude o reescreve a cada partida). Um agente pode plantar nele um servidor MCP
  global, que o seu Claude fora do sandbox executaria.
- **`launchctl` e `open` são bloqueados só pelo caminho** (`/bin/launchctl`, `/usr/bin/open`): uma cópia do binário
  roda. É defesa em profundidade. O `open` do terminal vira `collie open <url|app>` (veja abaixo).
- **Os caches graváveis guardam código que roda fora** (`~/.npm`, `~/.cache`, `~/.cargo/registry`, `go/pkg`, DerivedData):
  escrever neles pode virar execução fora do sandbox (`~/.npm/_npx`, ambientes do pre-commit).
- **A memória em `~/.claude/projects` é compartilhada com terminais livres:** texto escrito por um agente com sandbox
  pode chegar ao prompt do Claude de um terminal livre. O mesmo vale para a memória do próprio Collie: o que um agente
  com sandbox salva com `collie memory save --scope project|global` é injetado nos hooks de um terminal livre daquele
  projeto (ou de todos, no global). Revise as memórias (Revisar) antes de confiar nelas num terminal livre.
- **A proteção do `.git` aninhado é defesa em profundidade.** Dentro de `.build/` e `Carthage/Checkouts/` um repositório
  plantado vale; e um repositório preparado em `/tmp` e movido (rename) para dentro do projeto, com um gitlink no índice,
  ainda faz o seu git rodar a configuração dele. **Revise o que o agente mudou, incluindo gitlinks novos em
  `git diff --cached`, antes de rodar as suas próprias ferramentas no projeto.**
- **Configuração e scripts do projeto** (`.claude/settings.json`, `.mcp.json`, `.codex/`, `.cursor/`, `.envrc`,
  `.vscode/`, `package.json`, Makefile…) são graváveis, e rodam fora do sandbox quando você mesmo os executa.
- **Sandbox do próprio agente desligado.** O Seatbelt não aninha: o Collie liga o Claude com `sandbox.enabled=false`, o
  Codex com `--sandbox danger-full-access` e o cursor-agent com `--sandbox disabled`. Quem confina é o sandbox do Collie.
- **Admin:** isolamento de verdade exige os agentes sob outro usuário do macOS (veja "Ambiente dos agentes").

**Terminal livre.** Na folha de novo terminal, "Terminal livre (sem sandbox)" é para o seu trabalho: só você, só pelo app
(agente, `summon` e rebanho nunca criam um), sem guias (nenhuma guia chega a ele), fora dos lotes, e com a marca "livre"
no nó. Ele roda como o seu usuário, sem nenhuma proteção.

**Liberar acesso.** Quando o agente é bloqueado numa escrita fora do projeto que pode ser liberada, ele recebe o erro na
hora e o Collie mostra no nó do terminal um cartão: "Agente *X* tentou **escrever|apagar** `caminho`", com **Liberar este caminho**, **Liberar a pasta** e **Negar**, e a
opção "para o lote" (vale para os terminais atuais e futuros do lote). Nada é liberado sem o seu clique. Liberar reinicia
o terminal com o sandbox mais largo e, no Claude, retoma a conversa (`--continue`, só se já havia uma); no Codex e no
Cursor é uma reabertura simples. O processo em andamento se perde, a conversa não. Com "para o lote" só o terminal do
cartão reinicia; os outros membros recebem o acesso na próxima partida. Os liberados ficam salvos e aparecem no popover
do terminal e na aba "Liberados" do lote; **Revogar** reinicia na hora os terminais que ele alcançava. Um aviso
"detecção indisponível" no nó indica que o Collie não está vendo os bloqueios agora (os bloqueios continuam valendo).
O que um clique **nunca** libera: a pasta de dados e o token do Collie, segredos, `.git/hooks`, `.git/config`,
`.git/info/attributes`, `commondir` e qualquer `.git`/`*.git` (submódulos, worktrees, bare), `~/Library` e
`~/Library/Application Support` inteiros, `~/Library/{Keychains,Mail,Messages,Cookies,Safari,Containers,Group Containers}`,
o app do Collie e as pastas que o contêm (como `/Applications`), a escrita no que é "nunca gravável" (acima; a
configuração global dos agentes é liberável) e, num
terminal do pasto, a escrita nos cercados dele (abra um terminal no cercado). Esses bloqueios não geram cartão: são
silenciosos (o daemon conta, por terminal, os "bloqueios silenciosos" em `access.list`), como as leituras negadas. O
Claude Code sonda a pasta `NativeMessagingHosts` de cada navegador ao iniciar: isso também fica em silêncio. Só um pedido
do agente para um desses caminhos mostra um cartão, com só **Negar**.
Liberar escrita numa pasta dentro de `/tmp` não bloqueia o git ali (os temporários já são graváveis; clonar lá funciona).
Cada liberado guarda exatamente o caminho mostrado no cartão (resolvido uma vez); trocar um link depois não o alarga.
O agente também pode pedir: `collie access request <caminho> --write --reason "…"` (o motivo é limpo de segredos
e mostrado no mesmo cartão; se já houver um cartão aberto para aquela pasta, o pedido soma-se a ele e a resposta diz
isso). Um pedido `--read` não mostra cartão: a resposta diz que a leitura já é livre, ou por que aquele caminho nunca é
liberado. Liberados de leitura antigos continuam salvos e não fazem nada. Terminais livres não têm sandbox, então não pedem.

**`collie open <url|app>`.** O `open` do terminal chama o daemon, que o executa fora do sandbox só para URLs http(s)/mailto e
apps instalados (`/Applications`, `~/Applications`, os do Xcode: `open -a Simulator` funciona). Scripts, `.command`,
executáveis, documentos, pastas e apps construídos pelo agente são recusados; abra esses pelo Xcode ou pelo Finder.

**Ferramentas.** Há atalhos (shims) de `swift`, `swift-build`, `swift-test`, `xcrun swift` e `xcodebuild` no `PATH` do
terminal, que acrescentam `--disable-sandbox` e `-IDEPackageSupportDisableManifestSandbox=YES` (o sandbox do SwiftPM e do
Xcode não aninha). Chamar a ferramenta pelo caminho absoluto, ou usar um shell que não seja o zsh (o `path_helper` reordena
o `PATH`), traz de volta o erro de aninhamento. O histórico do zsh fica no estado do próprio terminal.

**Quem já tem terminais.** Os terminais existentes entram no sandbox na próxima partida; o app avisa uma vez ao abrir.

**Para desenvolver o Collie.** `collied --no-terminal-sandbox` liga os terminais sem sandbox (os testes usam; a decisão é
registrada no stderr na partida). Sem a flag o `collied` sempre sandboxa, em qualquer `--root` (`swift run collied --root
<pasta>`; no root padrão sem bundle assinado o admin é sempre recusado).

## Registro de trabalho

O daemon guarda, por terminal, o que o agente está fazendo: um **trabalho** com tarefas, jobs (subagentes e shells em
segundo plano), notas e commits. Os dados ficam em `<raiz>/work/` (`work.json`, 0600, e `work-archive.jsonl`).

**Limites:** 500 tarefas, 200 jobs, 200 notas e 200 commits por trabalho, e os 200 trabalhos fechados mais recentes.
O excedente vai para `work-archive.jsonl`; nada é apagado. Só o "limpar histórico" do app apaga (trabalhos fechados e o arquivo).

**Hooks do Claude Code** (gravados no `--settings` de cada terminal Claude; o Stop, o SessionStart e o UserPromptSubmit já existiam):

| Evento | Matcher | Comando |
|---|---|---|
| `PostToolUse` | `TodoWrite\|Task.*\|Agent\|Bash\|BashOutput\|KillShell` | `collie hook claude-tool` |
| `SubagentStop` | (todos) | `collie hook claude-subagent-stop` |
| `PreCompact` | (todos) | `collie hook claude-precompact` |
| `SessionEnd` | (todos) | `collie hook claude-session-end` |

Todos com timeout de 5 s; o hook nunca falha nem atrasa o agente (erros vão para `~/Library/Logs/Collie/hooks.log`).
Os nomes dos campos dos payloads (`tool_input`, `tool_response`, `agent_id`, `agentId`, `task_id`…) são **suposições, ainda
não verificadas contra payloads reais**; o parser é tolerante, mas confira com um Claude de verdade.

**Estados**
- Tarefa: `open`, `inProgress`, `done`, `deferred` (com motivo), `abandoned`.
- Job: `running`, `finished`, `gone`, `unknown`. `gone` só quando confirmado (o terminal morreu, ou o processo não existe
  mais); sem nenhum sinal por 30 minutos um job `running` vira `unknown`, e um sinal de fim posterior ainda o finaliza.
- Trabalho: ativo ou fechado (por `merge`, `agent:<terminal>` ou `app`); um ativo por terminal.

**Trabalho implícito:** sem trabalho ativo, o primeiro hook com tarefas, título de tarefa ou job abre um trabalho
chamado `"<nome do terminal> — AAAA-MM-DD"`, com o cercado e a branch do terminal. `collie work task add` e `collie work note` também abrem um.

**Comandos** (`collie work …`): `start`, `done [--reason]`, `reopen`, `task add|done|defer|drop` (defer/drop pedem o motivo),
`note`, `status [--all]`, `list [--closed]`, `get`. `clear-history` é só do app. Guias: um terminal vê só o próprio
trabalho; um Pastor vê também o dos terminais ligados por guia a ele (`--terminal`); o app vê tudo. Um terminal fora
do alcance dá o mesmo "não encontrado" de um inexistente.

**Fechamento por merge:** (1) ao `land` de um cercado (não no modo `pr`, que ainda não foi integrado); (2) no Stop, quando
há um commit desde que o trabalho abriu e a branch é ancestral do destino (a `baseBranch` do cercado, ou a branch do pasto).
Um trabalho sem branch nunca fecha sozinho. Os commits novos entram no trabalho a cada Stop.

**Codex e shell** não têm hooks: usam só os comandos explícitos `collie work …`.

## Painel Trabalho

Plug-in **Trabalho** (dock direito; abrir de novo só seleciona a aba existente). Mostra, por trabalho do workspace:
título, terminal · branch, tags de contagem por estado, tarefas e jobs ao clicar, e um ícone de alerta quando há job
`gone`/`unknown` ou aprovação pendente. Abaixo, o chat; os cartões de aprovação ficam acima da lista. O menu "…" de cada
trabalho tem **Recolocar no trilho** e **Fechar…** (fechados ficam recolhidos, com "Reabrir").

**Perguntas de status** (botões "Onde estamos", "O que travou", "O que está rodando"): o daemon responde com o registro,
**sem gastar tokens** e sem tocar no agente (mensagem `collie` em cinza). Só contam frases exatas, sem acento nem maiúsculas
(`onde estamos`, `status`, `como estamos`, `o que travou`, `o que falta`, `o que está rodando`, `rodando`…), com no
máximo palavras de enchimento no fim (`agora`, `ai`, `então`, `por favor`, `pf`, `me diz`, `hoje`). Qualquer outra coisa
pode ser uma instrução e vai ao agente sem alteração.

**Roteamento do chat:** (1) `@nome` (sem diferenciar maiúsculas) manda o resto do texto para esse terminal; (2) sem `@`,
com um trabalho selecionado: o Pastor do trabalho (o próprio terminal, se for Pastor; senão o primeiro Pastor ligado por
guia, em ordem de nome); (3) sem Pastor, o terminal do trabalho; (4) sem `@` e sem trabalho: "Escolha um trabalho ou
comece com @nome.". A mensagem é entregue depois que o agente fica 2 s calado e a resposta volta ao chat (até 30 min).
Chat e `work.chat.*` são só do app; terminais recebem "não autorizado".

**Aprovações.** Duas fontes alimentam a mesma lista de pendências por terminal:
- o **hook `Notification`** do Claude (`collie hook claude-notification`), que o Claude só envia **6 s** depois de abrir o
  diálogo, e só vale com `notification_type = "permission_prompt"`;
- o **padrão na tela**: a pergunta `Do you want to …?` com a opção `1. Yes` até 3 linhas depois (principal, pois não espera
  os 6 s), mais `(y/n)`, `[y/n]` e "press enter to continue".

Aprovar/Negar só escreve no terminal se **o mesmo pedido ainda está na tela** (o texto capturado aparece contíguo nas
últimas 40 linhas) e nenhuma tecla chegou desde então; senão responde "pedido não está mais pendente" e não escreve nada.
Teclas: menu do Claude, aprovar = `1`, negar = Esc; `(y/n)`, `y`/`n` + Enter; "press enter", Enter (negar só dispensa).
Se em 2 s o diálogo não reage (nenhuma saída), a aprovação volta a ficar pendente.
O cartão mostra o texto capturado inteiro; Enter nunca aprova. Aprovação "saída demais para conferir" (`unknown`) **nunca
escreve nada**: só "Entendi, vou olhar o terminal". Enquanto há aprovação pendente, o **chat e o `inject`** (chamar,
rebanhos, recolocar no trilho) **não digitam no terminal**. O `collie ask` simples continua podendo responder a um
pedido, por desenho (R7: é como um Pastor responde ao prompt de outro agente).

**Recolocar no trilho:** só a pedido (botão ou `collie work rerail [--terminal]`; Pastores só alcançam terminais ligados por
guia). Injeta no agente um bloco só com o **estado vivo** (tarefas em andamento/abertas, jobs rodando, 5 decisões mais
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
- CLI: `collie work summary [--id <trabalho>] [--terminal <nome>] [--natural]`. Sem `--id`, vale o trabalho ativo; `--terminal`
  é para Pastores (terminais ligados por guia); o alcance é o mesmo do `collie work status`. `--natural` pede a reescrita do
  modelo local; a resposta traz o markdown sempre, mais `natural` e, se não houve reescrita, o `reason`.
- Chat do painel Trabalho: a frase exata `resumo` (também `resume` e `o que foi feito`, com as mesmas palavras de enchimento
  das perguntas de status; qualquer outra coisa vai ao agente). Sem trabalho selecionado: "Escolha um trabalho para ver o
  resumo.". Não gasta tokens.
- Painel: botão **Resumo** e a seção Resumo do trabalho selecionado. Com a reescrita do modelo local, o link **Ver dados**
  alterna para o resumo do registro (e **Ver resumo** volta). Sem reescrita, o painel mostra o registro e a linha cinza
  "Resumo sem reescrita: ‹motivo›".

**Modelo local (opcional).** A reescrita em linguagem simples e as perguntas livres usam o FoundationModels da Apple:
precisam do **macOS 26 com Apple Intelligence ligada**. Roda **no aparelho**, sem rede e sem tokens. Em outros sistemas o
Collie funciona igual, só sem essas duas coisas. A reescrita tem **10 s** de prazo e a pergunta **20 s**; passou disso, vale o
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
revisada** (origem "Collie (resumo)", assunto `trabalho <id>`), em **texto simples**; aprove ou descarte em `memory.review`.
Reabrir e fechar de novo **substitui** o anterior. Trabalho vazio (sem tarefas, notas nem commits) não é guardado, nem um sem
repositório (fica no log). Uma falha ao guardar vira uma mensagem do Collie no chat; o fechamento não é desfeito.
**Limite documentado:** o controle de "já guardei este fechamento" fica em memória do daemon; depois de reiniciá-lo, o mesmo
fechamento pode ser guardado de novo.

## Memória e lotes

A memória do Collie vive em três escopos: **global** (vale em todo lugar), **projeto** (o repositório do terminal) e **lote** (um grupo de terminais com um objetivo, que só os membros enxergam). Memórias antigas, sem lote, são do projeto.

- **Isolamento.** Um agente lê o seu lote, o seu projeto e o global; nunca o de outro lote, nem no mesmo pasto. `collie memory search` sem opções devolve só isso. Só o app (você) e um Pastor que alcança todos os membros de um lote podem buscar ou entrar em outro (`--lot`, `--all`). Lotes não dão alcance: quem fala com quem continua sendo só a guia.
- **Quadro.** Cada lote tem um quadro (`collie lot board`, `collie lot post --kind handoff|question|status|answer --to <nome>`). Recados endereçados a você chegam no próximo prompt, uma vez; são dados de outro agente, não ordens.
- **Propostas.** Ao fechar um trabalho (e ao fim da sessão) o Collie propõe memórias. Elas ficam em Revisar → Propostas até você aprovar, editar ou descartar; depois de 14 dias sem revisão viram descartadas (restauráveis, nada é apagado sozinho). O Claude também é perguntado, no máximo uma vez por trecho de trabalho, o que vale registrar.
- **Promover.** Uma memória do lote pode ser promovida ao projeto (`collie memory promote`).

**O que é injetado, e quando** (até 4096 bytes no início, 2048 por prompt, fora a orientação do Collie):

| Quando | O que entra |
|---|---|
| Início | memórias fixadas e o índice (títulos) do lote (dentro de um lote) ou do projeto e global (fora de um) |
| Cada prompt | recados do quadro endereçados a você, os comentários do usuário nas suas páginas (veja Comentários), depois as memórias relevantes ao prompt, sem repetir |
| Depois de compactar (e ao retomar) | seu trabalho ativo (tarefas abertas e as 3 últimas notas), o último recado do quadro para você e os 3 últimos status do lote, depois o índice de memórias |

O recado entregue na compactação não é repetido no prompt seguinte. Só o Claude recebe essa injeção (início, prompt e compactação). O Codex ainda não recebe nada no início nem no prompt (não tem esse gancho): leia os recados com `collie lot board` e os comentários com `collie comment list`. O preset do Cursor ainda não está disponível.

## Backup dos dados

Menu **Arquivo → Exportar dados do Collie…** gera um `.zip` (0600) com `manifest.json` na raiz.

- **Entra:** `design/` (inclui o servidor do Design), `artifacts/`, `memory/`, `workspaces/` (sem o spill de terminais
  em `workspaces/*/terminals`), `work/`, `herds/`, `lots/`, `comments/` (comentários nas páginas) e o workspace padrão (no manifesto).
- **Fica de fora:** `run/`, `hooks/`, `cache/`, `usage/`, `admin.token`, `screens/` e o `.collie/memory` de cada repositório.
- O arquivo guarda os links do Design: **trate como uma senha**.
- A exportação pausa o Design por instantes (os painéis reconectam; o Design responde "backup em andamento" nesse intervalo).
- **Importar** (**Arquivo → Importar dados do Collie…**): valida o arquivo e mostra a contagem (designs, design systems,
  artifacts) sem mexer em nada; pede confirmação de que o serviço vai reiniciar e os terminais abertos vão fechar. O
  import é aplicado no próximo start do serviço; os dados atuais vão para `<raiz>/.replaced-<ms>` (nada é apagado).

## Rebanhos

Um rebanho é uma equipe pronta: terminais (com preset, papel/prompt inicial e posição), painéis, guias e, se quiser, um cercado.

- **De fábrica:** *Feature fullstack* (Pastor, backend, interface e revisor, com painéis Design e Navegador; pede cercado) e
  *Investigar bug* (Pastor, investigador e testes). Não podem ser substituídos nem removidos.
- **Salvar:** menu do canvas ou ⌘K → "Salvar canvas como rebanho…" / "Salvar seleção como rebanho…". Só entra o estado
  permitido: do Design o arquivo e o armazenamento, do Navegador o endereço http(s) (sem usuário e senha; com
  aviso se tem parâmetros `?…`) e o armazenamento. Painéis de
  dispositivo (e os demais plug-ins) são pulados, com aviso. Nunca vão para o arquivo: histórico de terminal, tokens, links
  do Design, variáveis de ambiente, caminhos absolutos e `cwd`.
- **Aplicar (tudo ou nada):** ⌘K → "Aplicar rebanho…", a seção REBANHOS da barra lateral ou "Aplicar rebanho aqui…" no
  canvas. A prévia lista tudo que será criado, com cada comando e cada prompt; **Aplicar** só libera depois de rolar até o fim.
  Se qualquer passo falha (ou um terminal fica parado numa pergunta, como confiar na pasta), o que foi criado é desfeito.
  O desfazer remove só o que esta aplicação criou: terminais e painéis; o cercado é removido apenas se não tem commits,
  alterações não commitadas nem arquivos ignorados (build, `.env`) e nenhum terminal ficou nele — senão fica, com aviso.
  Arquivos de design criados também ficam, com aviso. Se o serviço cair durante a aplicação, o que já foi criado fica;
  remova à mão.
- **Onde:** aplicada pelo app, a equipe nasce no cercado que está na tela (a pasta padrão é a do cercado); se o rebanho pede
  cercado, um novo é criado e o app vai para ele. Um Pastor aplica sempre no seu próprio cercado e na sua pasta.
- **Arquivo `.collieherd`:** JSON com `format: 1`, até 256 KiB, 20 terminais e 20 painéis; campos desconhecidos são
  ignorados. Tamanhos de 320×200 a 4000×4000 (painéis a partir de 200×200), posições até 100000. **Exportar…** e **Importar…** estão na folha de Rebanhos. Um arquivo importado não é confiável: a tela de
  confiança mostra cada comando (`preset: custom`) e cada prompt antes de guardar, e importar não cria nada até você aplicar.
  Se já existe um rebanho salvo com o mesmo id, a tela oferece **Substituir**. O aplicar envia o resumo (digest) da
  prévia: se o rebanho mudou desde então, o daemon recusa.
- **Pastor:** `collie herd list`; `collie herd apply <id> --name <nome> [--paddock true|false]` (tudo que cria fica
  ligado por guia ao Pastor, com as regras de `paddock create` e `panel open`); `collie herd save <nome> --terminals a,b,c
  [--panels …]`. Remover, importar e exportar são só do app.
- **Backup:** os rebanhos salvos (`<raiz>/herds/`) entram no backup dos dados (veja abaixo).

## Notas

- **Cercados (paddocks):** `paddock.list` é visível a todo terminal gerenciado (nomes, caminhos e branches de todos os
  cercados). Criar é só para Pastores; integrar/excluir, só para o Pastor criador ou o usuário; land `pr`, só o usuário.
- **Painel de uso:** os provedores ficam em `~/Library/Application Support/Collie/usage/providers/*.json` (semeados uma vez). O provedor Claude vem
  desativado: não há fonte local de uso que não envie um prompt. O provedor Codex não foi verificado contra a saída
  real do `codex`.

## Licença

MIT — veja [LICENSE](LICENSE). Componentes de terceiros embutidos no app: `Resources/NOTICE-*`.
