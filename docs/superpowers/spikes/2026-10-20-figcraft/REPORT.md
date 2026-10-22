# Spike figcraft v0.7.0 — fonte única ao vivo para Orq (Fase 2)

Data: 2026-10-20 · figcraft tag `v0.7.0` (commit `47438dd4`) · clone em `figcraft/` neste diretório.
Tudo rodou em 127.0.0.1; todos os processos iniciados foram parados no fim.

**Resumo:** o caminho **(a)** funciona hoje, sem patch: um `figcraft-server` local guarda o arquivo,
a UI WASM entra na sessão e agentes (`figcraft-cli mcp` headless) também entram via `collab.join`.
Todos editam **o mesmo documento ao vivo** (o servidor ordena; não há cópias sincronizadas por nós).
Prova feita com o portfólio real (seção 6). Há bugs/arestas pequenos, todos listados abaixo.

---

## 1. Arquitetura do figcraft v0.7.0 (como encontrada)

Workspace Rust (`Cargo.toml`, edition 2024, rust >=1.95), camadas impostas por `cargo xtask layers`
(`docs/architecture.md`, `xtask/src/layers.rs`):

| Camada | Crate | Papel |
|---|---|---|
| L1 | `crates/doc` | Modelo: páginas, nós num mapa persistente (`imbl`, ids estáveis), componentes, estilos, variáveis (coleções + modos), protótipos |
| L2 | `crates/layout` | Auto layout (horizontal/vertical/wrap/**grid**, hug/fill/fixed, min/max) |
| L2 | `crates/text` | Fontes (craft-fonts embutidas opcionalmente via `CRAFT_FONTS_DIR` + scan do sistema), shaping |
| L2 | `crates/collab` | Núcleo de colaboração sem rede: objetos/propriedades, change sets, ordenação no servidor, reconciliação, **undo por usuário** |
| L3/L4 | `render`, `format`, `svg`, `pdf` | Render CPU (tiny-skia), `.figcraft` (zip+JSON), SVG/PDF |
| L5 | `crates/engine` | `Session`, undo por snapshots `Arc`, **registro de comandos** (`cmd/*`, macro `spec!`, ~455 ids), codegen Dev Mode (`codegen.rs`, `component_codegen.rs`), sessão ao vivo (`live.rs`), panic guard (`guard.rs`) |
| L6 | `crates/ui-egui` | UI egui (+ canal de controle `control.rs`) |
| L6 | `crates/mcp` | Servidor MCP stdio: backend **headless** (`headless.rs`) ou **attached** (`--attach <porta>` -> app desktop) |
| L6 | `crates/collab-net` | WebSocket (tungstenite / `web-sys` no browser), hub de sessões, clientes |
| apps | `figcraft` (desktop eframe/wgpu), `figcraft-cli` (`run`, `export`, `mcp`), `figcraft-web` (WASM via trunk), `figcraft-server` (servidor de colaboração persistente) |

Pontos-chave:
- **Tudo é comando**: menus, atalhos, CLI, canal de controle, MCP e plugins chamam os mesmos ids
  (`crates/engine/src/cmd/*`). `command.batch` (`cmd/edit.rs:333`) = vários comandos num **único passo
  de undo**, tudo-ou-nada, com referências `{"$step": n}` (`engine/src/lib.rs` ~120-145).
- **Colaboração** (`docs/collab-protocol.md`): servidor central autoritativo, mensagens binárias via
  WebSocket, sincroniza **estado** (prop P do objeto O = V), last-writer-wins por propriedade na ordem
  do servidor; cliente aplica otimista e reconcilia. Não é CRDT nem OT. Undo/redo por usuário (desfaz
  só os próprios passos). Dados derivados (auto layout, instâncias, bindings) calculados pelo autor.
- **Headless MCP também participa de sessões**: `Headless::with_session` instala `NetLink`
  (`crates/mcp/src/headless.rs:50`); `collab.join/publish/host/peers` são comandos comuns
  (`docs/mcp.md` §Live sessions, `docs/collab-protocol.md` §Agents). Isso derruba a premissa do spec
  de que "headless edita cópia própria" — só vale se o agente **não** fizer `collab.join`.
- **Web build** (`apps/figcraft-web/src/main.rs`): mesmo `FigApp` do desktop, entra em sessões (não
  hospeda), aceita `#join=<link>` na URL, `?webgl` força WebGL2. A release traz `figcraft-web-0.7.0.zip`
  pronto (21 MB; wasm ~18 MB).
- **figcraft-server** (`apps/figcraft-server`, `docs/server.md`): arquivos persistentes (snapshot + log),
  links de edição/visualização com token, chave de servidor, `--listen` default `127.0.0.1:47900`.
- **Canal de controle** (`docs/control-protocol.md`): JSON por linha em TCP 127.0.0.1, só no app
  desktop, máx. 8 conexões/8 requisições na fila, executa no thread de UI.

## 2. Avaliação dos caminhos

### (a) `figcraft-server` + UI WASM + agentes como clientes da sessão — FUNCIONA (recomendado)

O que rodei (scripts em `scripts/`):
1. `cargo build --release -p figcraft-server -p figcraft-cli` com cargo Homebrew 1.97 -> ok (12 min,
   sem craft-fonts; target em `target/`).
2. `figcraft-server --listen 127.0.0.1:47900 --data srvdata` (+ `figcraft-server key`).
3. `scripts/spike_a.py`: agente = `figcraft-cli mcp` headless faz `collab.publish` de um doc vazio; um
   segundo `figcraft-cli mcp` ("UI stand-in") faz `collab.join` com o link de edição; o agente cria
   tokens + portfólio num `batch` de 216 comandos. Saída (`spike_a.log`):
   ```
   batch of 216 commands ok in 0.39s
   ui saw root after ~0.1s polling
   agent sees UI rename: True                 <- edição da "UI" chegou no agente
   ui root after agent setMode Dark: ... "fills": [{"color": "#111317" ...   <- edição do agente chegou na "UI"
   export html: 17307 bytes                   <- exportado da cópia do cliente "UI"
   ```
   Latências medidas: retângulo agente->UI ~0.00 s (na próxima chamada), batch de 216 comandos
   agente->UI 0.33 s, UI->agente ~0.00 s; publish até gravável 0.12 s.
4. **UI WASM real**: servi o zip da release em `http://127.0.0.1:47911/` e abri no Chrome com
   `#join=figcraft://join?host=127.0.0.1:47900&file=...&token=...` -> diálogo "Join live session"
   já preenchido -> Join -> o portfólio apareceu (camadas Hero/Experience/Skills/Education/Contact,
   34 variáveis no painel, seletor de modo). Depois um **novo agente headless** entrou na sessão,
   trocou o modo para Dark e renomeou o frame: **a UI web mudou ao vivo**
   (`portfolio/wasm-ui-live-after-agent-dark.jpg`, nome da camada "Portfolio (agent switched to Dark)").
5. **Undo de batch = 1 passo, em sessão** (dois clientes): após o batch, **um** `undo` do agente
   removeu o portfólio inteiro nos dois clientes; `redo` trouxe de volta; `undo` do outro cliente (sem
   passos próprios) não mexeu no trabalho do agente. (Variáveis criadas antes do batch eram passos
   separados; no import real, ponha tudo no mesmo batch.)

Bloqueadores/arestas encontrados:
- **Bug: leituras headless em sessão ficam velhas.** `Headless::execute` faz `live_poll()` antes de cada
  comando, mas os tools de leitura `get_node`, `inspect_document`, `screenshot` (`Headless::call` ->
  `"node.get"`, `"document.inspect"`, `"ui.render"`, `crates/mcp/src/headless.rs:238-275`) **não**
  fazem poll. Observado: o cliente não via o root por >10 s até rodar algum comando. Contorno: rodar
  `run_command collab.peers` antes de ler (o wrapper do Orq faz isso). Patch upstream de 1 linha
  (`self.session.live_poll()` no topo de `call`).
- **Editar durante o upload do `collab.publish`** (status `live` mas `readOnly: true`) não dá erro, mas a
  propagação atrasa. Esperar `readOnly == false`.
- **Texto não aparece no canvas da UI WASM** (frames, cores e modos aparecem; os nós de texto existem
  nas camadas e no doc). Causa provável: fonte `Inter` — o browser não tem fontes do sistema, e o
  headless que criou os textos foi compilado sem craft-fonts (`text.fonts {family:"Inter"}` -> `[]`).
  Causa raiz **não confirmada** no time-box; é o primeiro item a fechar (testar família embutida no
  build web / web build com `CRAFT_FONTS_DIR`). `portfolio/wasm-ui-zoomed-text-missing.jpg`.
- O agente precisa fazer `collab.join` sozinho (não existe `figcraft-cli mcp --join <link>`). Orq
  resolve com wrapper/skill que faz o join no início, ou patch pequeno no CLI.
- Ids em sessão vêm do espaço do cliente (ex. `4294967312`, `VariableID:4294967298`); o adaptador
  não pode assumir ids pequenos.
- `node.get` via `run_command` devolve `null` para nó inexistente; o tool `get_node` devolve erro.

Integração Swift (proposta):
- O daemon do Orq sobe `figcraft-server --listen 127.0.0.1:<porta> --data <App Support>/design`
  (processo auxiliar; `GET /healthz`). Cada tela/design system = um arquivo no servidor.
- **UI**: WKWebView carregando o site web (servido localmente, ou `WKURLSchemeHandler`) com
  `#join=<link de edição>`; `?webgl` se WebGPU falhar no WKWebView. `ws://127.0.0.1` a partir de
  página `http://` funciona (testado no Chrome; WKWebView a validar).
- **IPC do Swift** (`DesignEngine`): processo `figcraft-cli mcp` headless "bridge", já com
  `collab.join` no arquivo ativo, falando JSON-RPC por stdio (export, screenshot, import em batch,
  troca de design system). Sem linkar Rust.
- **Agentes**: cada um com `figcraft-cli mcp` (via `.mcp.json`) envolto num wrapper que faz o join e
  o "poll antes de ler"; `--automation-read-root/--automation-write-root` confinam o disco.
- Esforço: 3-5 dias (adaptador + wrapper + WKWebView) + 1-2 dias (fontes no web, patch do poll).
  Fragilidade: média — protocolo marcado "draft" (`collab-protocol.md`), API alpha; servidor, CLI e
  web precisam estar na **mesma versão** (pin v0.7.0 nos três).
- Branding: seção 5 — exige rebuild do web.

### (b) App desktop + `--control` + MCP attached — funciona, mas pior

Não compilei o app desktop (time-box; (a) já provou o mesmo motor). Pelo código: canal de controle só
no app desktop (`apps/figcraft/src/control_server.rs`), executa no thread de UI, limite de 8 conexões e
8 requisições na fila (`docs/control-protocol.md`) — vários agentes em paralelo esbarram nisso; janela
egui/wgpu separada (não embute em WKWebView, contraria "UI dentro do Orq"); branding exige rebuild do
app. Dá fonte única (o app é o documento), mas com um processo gargalo. O app desktop **também** entra
em sessões do servidor, então (b) vira caso particular de (a) se um dia quisermos a janela nativa.
Esforço 2-3 dias; UX ruim.

### (c) Processo Rust próprio sobre `figcraft-engine` — desnecessário agora

Reimplementaria o que `figcraft-server` (hub) + `figcraft-cli mcp` headless (cliente) já fazem.
Custo 1-2 semanas + acompanhar API alpha do engine a cada release. Só se precisarmos de algo que o MCP
não expõe (ex. stream de eventos de mudança para o Swift sem polling) — e isso cabe num patch pequeno
ao CLI. Fica como fallback.

## 3. Gap check contra o contrato `DesignEngine`

| Requisito | Status | Evidência |
|---|---|---|
| Documento único editável ao vivo por UI e agentes | OK via (a) | seção 2(a), passos 3-4 |
| Variáveis / tokens com modos claro/escuro | OK no design | `variable.createCollection {modes}`, `variable.create {values:{Light,Dark}}`, `variable.bind`, `variable.setMode` (`cmd/styles.rs:112-197`); render Light/Dark ok |
| Componentes / instâncias / variantes | OK (não exercitado no portfólio) | `engine/src/components.rs`, `docs/components-parity.md`, `component_codegen.rs` |
| Auto layout | OK | vertical/horizontal/wrap/grid; usado no portfólio todo |
| Export HTML/CSS | PARCIAL | `inspect.code {language: html/css/react/...}` (`codegen.rs:17`); lacunas abaixo |
| Screenshot | OK | tool `screenshot` (headless, render CPU) -> PNGs em `portfolio/` |
| Import em lote como 1 passo de undo | OK | `batch`/`command.batch`, inclusive em sessão (teste de undo) |
| Importar HTML | NÃO EXISTE | como previsto em §7.1.1 — Orq faz DOM->comandos e manda num `batch` |

Lacunas do export HTML (confirmadas no código e na saída):
- Só `<div>` e `<p>` (`codegen.rs` ~750-790); sem `h1/section/ul/a`; link não vira `<a>`.
- Imagens viram `background: url(image.png)` placeholder (`codegen.rs:451`); padrões `url(pattern.png)`.
- Vetores não são inlinados como `<svg>`.
- Auto layout -> **só flexbox** (`codegen.rs:374`); `layout: grid` não vira `display: grid`.
- **Variáveis -> `:root` só com o valor do modo atual**, sem bloco de Dark (`Tokens::root_rule`,
  `codegen.rs:300-321`). Tema escuro no HTML é por nossa conta.
- Vistos no portfólio: `font-family: "Inter"` sem fallback nem `@font-face` (Chrome caiu em serif);
  `<p>` sem reset de margem (espaçamento dobra); larguras fixas em px (`width: 1072px` com
  `align-self: stretch`) -> não responsivo; fragmento sem `<html>/<body>`; classes derivadas do nome
  da camada.

## 4. Recomendação

**Caminho (a)**: `figcraft-server` local + UI WASM em WKWebView + agentes e bridge Swift como clientes
`figcraft-cli mcp` headless na mesma sessão. Fonte única real, funcionando com os binários da v0.7.0.
Não é preciso trocar de motor (por isso não listei alternativas). Antes do plano detalhado:
(1) resolver texto invisível na UI web (fontes); (2) patch/contorno do poll nas leituras headless;
(3) wrapper de join para agentes; (4) pós-processador do export HTML (semântica, reset, fontes, modos
via `[data-theme]`) ou contribuição upstream ao `codegen.rs`; (5) validar WebGPU/WebGL2 no WKWebView.

## 5. Instalações que precisariam de aprovação

Nada foi instalado. Para o que foi provado aqui **não precisa de nada** (cargo Homebrew compila
server/CLI; o web veio do zip da release, sha256 conferido com `SHA256SUMS.txt`).

Para **remover a marca ArtCraft** (requisito §3) é preciso recompilar o web build (e o desktop, se usado):
- `rustup` (o Rust do Homebrew não traz a std de `wasm32-unknown-unknown`: o sysroot só tem
  `aarch64-apple-darwin`) + `rustup target add wasm32-unknown-unknown`;
- `trunk` e `wasm-bindgen-cli` (na versão do `Cargo.lock`) — dá para instalar local com
  `cargo install --root <scratch>/tools`;
- opcional: checkout de `storytold/craft-fonts` como `CRAFT_FONTS_DIR` (provável correção das fontes).

Branding a trocar (~0,5 dia): `crates/ui-egui/src/dialogs.rs:134-141` (About: texto, links
getartcraft/Discord), `crates/ui-egui/src/lib.rs:964` (`open.help` -> getartcraft.com),
`crates/ui-egui/locales/*.toml` (2 strings x 13 idiomas), `apps/figcraft/build.rs:14` (CompanyName,
só desktop). Também compilar com **`FIGCRAFT_DEFAULT_SERVER=`** (vazio) para desligar o servidor público
padrão `wss://collab.craftapps.dev/` (`crates/engine/src/live.rs:66-70`), evitando que "Share > Online"
publique fora da máquina.

## 6. Portfolio (prova com artefato real)

Conteúdo: um perfil de portfólio de exemplo (fora do repo).
O agente (headless MCP **em sessão no figcraft-server**) criou a coleção "Portfolio Tokens" (modos
Light/Dark; cores bg/surface/text/muted/accent; números space s/m/l/xl, type body/h3/h2/h1,
radius/card) e o portfólio inteiro num único `batch` de 216 comandos (`scripts/portfolio.py`): frame
raiz com auto layout vertical e seções Hero, Experience (3 cards), Skills (4 grupos), Education (4),
Contact — gap/padding/fontSize/cores/raio **ligados a variáveis**. O outro cliente da sessão viu o
mesmo documento; a UI WASM real também (frames, cores, modo), exceto o texto (ver 2a).

Arquivos em `portfolio/`:
- `portfolio.figcraft` — o documento (salvo pelo agente a partir da sessão).
- `portfolio-light-from-ui-client.png`, `portfolio-dark-from-ui-client.png` — render do figcraft feito
  pelo **outro** cliente da sessão depois do agente trocar o modo (Light/Dark via variáveis).
- `export-html.html`, `export-css.css`, `export-react.tsx` — saída do `inspect.code` **como veio**, sem
  edição, tirada da cópia do cliente "UI".
- `export-html-rendered-in-chrome.png` — o HTML exportado aberto no Chrome headless.
- `wasm-ui-live-after-agent-dark.jpg` — UI WASM no Chrome após o agente trocar para Dark ao vivo.
- `wasm-ui-zoomed-text-missing.jpg` — zoom mostrando o texto ausente no canvas web.

O que o export errou:
- Sem tema escuro: `:root` só tem os valores Light.
- `Inter` sem fallback/`@font-face` -> serif no browser. No render headless (sem craft-fonts) o
  **negrito** (`fontStyle: Bold`, exportado como `font-weight: 700`) saiu regular.
- Margens padrão de `<p>` somam com o `gap` -> espaçamento vertical bem maior que o design.
- Larguras fixas em px (não responsivo); cards de Skills ficaram mais estreitos que os de Experience.
- Tudo `<div>/<p>`: nome não é `<h1>`, bullets não são `<ul><li>`, links não são `<a href>`.
- Classes geradas do nome da camada (o rename "Portfolio (renamed by UI)" virou a classe raiz).

## Arquivos do spike
- `scripts/mcp.py` (cliente MCP stdio mínimo), `scripts/portfolio.py`, `scripts/spike_a.py`, `spike_a.log`
- `build.log`, `server.log`, `dl/` (zip web da release + SHA256SUMS), `srvdata/` (dados do servidor)
