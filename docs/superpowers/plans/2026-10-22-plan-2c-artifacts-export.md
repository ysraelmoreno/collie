# Plano 2C — Artifacts + export HTML de verdade — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `design.export --format html` passa a gerar uma página completa e usável (tags semânticas, reset, fontes com fallback, modos claro/escuro do design system ativo via `[data-theme]`, responsivo básico, grid, ícones SVG inline, imagens como arquivos), cada export vira um **artifact** versionado com miniatura, origem e "desatualizado", e um painel de doca **Artifacts** lista exports e HTMLs registrados por agentes, com abrir no Design, abrir no Navegador e reexportar.

**Architecture:** O export continua sendo o codegen do figcraft (`inspect.code {language: html}`); um **pós-processador Swift puro** (`HTMLExport`) reescreve a saída usando a árvore de camadas (`get_node` depth 64), as variáveis com todos os modos (`variable.list` da tela + do arquivo do design system ativo) e os assets do Inspect (`inspect.assets` + `file.exportLayers {assets: true}`). O vínculo elemento↔camada é exato: o codegen percorre as camadas visíveis em pré-ordem e nomeia classes com `class_name` (`vendor/figcraft-src/crates/engine/src/codegen.rs:580`), que portamos; qualquer divergência desliga só as regras que dependem da camada (com aviso), nunca põe tag errada. Um patch pequeno no figcraft expõe o link do texto no `get_node`. Artifacts ficam em `<root>/artifacts/` (registro + uma pasta por versão); o Navegador as abre por um esquema `orq-artifact://` servido só dessa pasta.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI (painel), CryptoKit (carimbo), WebKit (`WKURLSchemeHandler`); figcraft v0.7.0 do 2A + patch `0003`. Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.1 (lacunas do export; "HTML exportado usa o CSS do design system ativo"), §7.2, §7.3 (Artifacts), §7.4 ("pré-visualização de artifacts"), §6 (cordas, eventos `artifact.exported`). Roteiro: `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`. Spike: `docs/superpowers/spikes/2026-10-20-figcraft/REPORT.md` §3 (lacunas confirmadas). Base: `main` em `85f1b23` (2A+2B mergeados).

## Global Constraints

- **Design é a fonte da verdade** (spec §7.1): HTML é sempre export; nada edita o design a partir do HTML neste plano. HTML de agente só é **registrado e arquivado** (somente leitura); a importação como tela é o 2D (o artifact fica "aguardando importação").
- HTML de agente entra **só pelo comando de artifact** (agente registra explicitamente), nunca por varredura do disco (spec §7.3).
- **Corda é a única permissão.** `design.export` mantém as regras do 2A (painel alcançável). `artifact.*` é plug-in de **doca** (global ao workspace): qualquer agente lista/lê/registra; **reexportar e remover são só do app** (reexportar lê o design sem painel — agentes reexportam via `design.export`, que exige alcance).
- Segredos do 2A continuam: nenhum link/chave em resultado, arquivo exportado ou erro (scrubber em tudo que vem do motor).
- **Nada sai da máquina.** O HTML exportado não referencia rede: sem CDN, sem fontes remotas; assets ao lado (`assets/`).
- **Nada é apagado sem o usuário:** reexportar cria versão nova (as antigas ficam); remover artifact (só app, com confirmação) move a pasta para `<root>/artifacts/.removed/`.
- Links exportados só com esquemas seguros (`http`, `https`, `mailto`, `tel`, `#…`, relativos); outros são descartados com aviso. Texto e atributos sempre escapados.
- Nada de I/O bloqueante no pool cooperativo (`UnixSocketClient.offPool` / `DesignService.write`); protocolo `v: 1`; textos de UI em português; testes com fakes + build real em `vendor/figcraft` (gated `realBuilt`, dentro da suíte `.serialized` de design).
- Clean-room: nada de código/texto do Maestri; o patch do figcraft segue a licença dele (MIT/Apache) e vai em `patches/figcraft/`.

## Review Focus

1. **Camadas com nomes repetidos, vazios, com acentos ou começando com dígito** (`"Card"`×3, `""`, `"Seção"`, `"2024"`) → classes iguais às do figcraft (`card`, `card-2`, `layer-`, `se-o`, `layer-2024`) e vínculo correto. Teste: Task 2 `classNamesMatchFigcraft` + `attachHandlesDuplicatesAndHidden`.
2. **Árvore que não bate com o markup** (camada nova entre o `get_node` e o `inspect.code`, profundidade > 64) → export sai com o fallback estrutural (`main`/`section`/listas por marcador) e aviso `layer map mismatch`, nunca com heading/link na camada errada. Teste: Task 2 `attachMismatchAttachesNothing`, Task 3 `unmappedUsesStructuralRulesOnly`.
3. **Conteúdo hostil** (texto `<script>`, link `javascript:`, URL com aspas, SVG com `onload`) → texto escapado, link descartado, SVG vira `<img>`. Teste: Task 3 `unsafeLinksDropped`, Task 4 `unsafeSVGBecomesImg`.
4. **Origem some ou motor fora** (arquivo/camada apagados, servidor reiniciando durante `artifact.list`) → item continua listado com `missing`/`unknown`, a lista responde dentro do prazo. Teste: Task 7 `listMarksMissingAndUnknown`.
5. **Dois exports da mesma camada ao mesmo tempo / reexport em sequência** → versões distintas (`v1`, `v2`), nenhuma sobrescrita. Teste: Task 6 `concurrentExportsGetDistinctVersions`.

---

## File Structure

```
patches/figcraft/0003-inspect-hyperlink.patch          get_node expõe "hyperlink" do texto
scripts/capture-html-fixtures.sh                        gera Tests/Fixtures/html-export/* do motor real
Tests/Fixtures/html-export/{doc.json,pixel.png,code.html,node.json,variables.json,assets.json,export-files.json}
Sources/OrqDaemonKit/Design/ExportMarkup.swift          parse do markup do figcraft, Layer, className, attach
Sources/OrqDaemonKit/Design/ExportSemantics.swift       tags semânticas, listas, links, serialização
Sources/OrqDaemonKit/Design/ExportStyles.swift          CSS: parse, reset, fontes, temas, grid, responsivo
Sources/OrqDaemonKit/Design/HTMLExport.swift            build(): documento completo + assets
Sources/OrqDaemonKit/Design/DesignService.swift         (+ ExportSnapshot, snapshot/stamp por cliente do chamador e do daemon)
Sources/OrqDaemonKit/Artifacts/ArtifactStore.swift      registro + pastas de versão + arquivo de agente
Sources/OrqDaemonKit/ArtifactCommands.swift             artifact.* e o design.export html integrado
Sources/OrqDaemonKit/{CommandRouter,DesignCommands,Daemon}.swift
Sources/OrqProtocol/Plugins.swift                       (+ plug-in artifacts, comandos artifact.*)
Sources/OrqPlugins/{ArtifactsPanel,BrowserPanel}.swift  painel + esquema orq-artifact no Navegador
Sources/OrqApp/OrqApp.swift                             registro do painel
Tests/OrqDaemonKitTests/{HTMLExportTests,ArtifactTests}.swift, Tests/OrqPluginsTests/ArtifactsPanelTests.swift
Tests/Fixtures/fake-figcraft-mcp.py                     respostas do fixture html-export
```

---

### Task 1: Patch do link + fixtures capturados do motor real

**Files:** Create `patches/figcraft/0003-inspect-hyperlink.patch`, `scripts/capture-html-fixtures.sh`, `Tests/Fixtures/html-export/*`, `Tests/OrqDaemonKitTests/HTMLExportTests.swift`

**Interfaces:**
- Produces: `get_node` de um texto com link (`text.link`) traz `"hyperlink": "<url>"` (só quando `t.style.link` é `Some`), inserido no ramo de texto de `node_json` em `crates/engine/src/inspect.rs` logo após `"characters"`.
- Produces: fixtures (JSON exatamente como o motor responde, `text` do resultado MCP decodificado): `node.json` (`get_node {id: <raiz>, depth: 64}`), `code.html` (`inspect.code {id, language: html}` → campo `code`), `variables.json` (`variable.list`), `assets.json` (`inspect.assets {ids:[raiz]}`), `export-files.json` (`file.exportLayers {ids:[raiz], assets: true}`, sem `dir` → `data` base64).
- Documento do fixture (`doc.json`, comandos para `figcraft-cli run`, com `$step`): coleção `Tokens` modos `Light`/`Dark`; variáveis `color/bg` (#FAFAF7/#111317), `color/text` (#16181D/#ECEDEF), `space/m` (16/16, number); frame raiz `Landing` 800×auto vertical, gap 16 ligado a `space/m`, padding 24, fill ligado a `color/bg`; dentro, em ordem: frame `Hero` vertical com textos `Title` 48px "Hello" (`sizingH: fill`, fill ligado a `color/text`), `Subtitle` 20px "Sub", `Body` 16px "Body text one" e `Body` 16px "Body text two"; texto `Items` 16px "One\nTwo" com `listStyle: bulleted`; frame `List` vertical com textos `Bullet` "• Alpha" e `Bullet` "• Beta"; texto `Link` "Site" + `text.link https://example.com`; texto `Bad link` "x" + `text.link javascript:alert(1)`; frame `Features` `layout: grid`, `gridColumns: 3`, `columnTracks: ["1fr","1fr",200]`, `sizingH: fill`, com 3 retângulos `Card` 50×50; estrela `Icon Star` 24×24; retângulo `Photo` 64×64 com imagem (`image.place` de `pixel.png`, PNG 2×2 gerado pelo script); texto `Hidden` "secret" com `visible: false`; frame `Footer` com texto `Copy` "©".

- [ ] **Step 1:** Escrever o patch (diff contra o `vendor/figcraft-src` limpo, mesmo formato de `0002`). Rodar `scripts/build-figcraft.sh` (reaplica o conjunto porque a soma muda; rebuild incremental) e `scripts/check-figcraft.sh`. Esperado: `ok: …`.
- [ ] **Step 2:** Escrever `scripts/capture-html-fixtures.sh`: gera `pixel.png`, roda `doc.json` com `figcraft-cli run --no-system-fonts --out <tmp>.figcraft`, abre o arquivo num `figcraft-cli mcp --automation-read-root <tmp>` (JSON-RPC por stdin: `initialize`, `open_file`, depois os `tools/call`), e grava os fixtures formatados (`python3 -m json.tool`, chaves como vieram). Sem caminhos de usuário nos fixtures (só `<tmp>` anonimizado ou nenhum).
- [ ] **Step 3: Teste** `HTMLExportTests.fixtureHasHyperlinkAndModes`: `node.json` tem um filho `name == "Link"` com `hyperlink == "https://example.com"`; `variables.json` tem a coleção com modos `["Light","Dark"]`; `assets.json` tem um `icon` (`Icon Star`) e um `image` (`Photo`); `code.html` contém `class="landing"` e não contém `secret`.
- [ ] **Step 4:** `swift test --filter HTMLExportTests` → PASS. Commit `feat(design): expose text links in get_node and capture html export fixtures`.

### Task 2: Markup do figcraft → árvore ligada às camadas

**Files:** Create `Sources/OrqDaemonKit/Design/ExportMarkup.swift`; Test `Tests/OrqDaemonKitTests/HTMLExportTests.swift`

**Interfaces:**
- Produces:
  - `struct Attr: Equatable, Sendable { var name: String; var value: String }`
  - `struct GridTrack: Equatable, Sendable { var sizing: String /* fixed|fill|hug */; var value: Double }`
  - `struct Layer: Equatable, Sendable { var id: String; var name: String; var type: String; var visible: Bool; var characters: String?; var fontSize: Double?; var listStyle: String?; var hyperlink: String?; var layoutMode: String? /* horizontal|vertical|grid */; var gridColumns: Int?; var columnTracks: [GridTrack]; var crossGap: Double?; var children: [Layer] }`
  - `struct MarkupNode: Equatable, Sendable { var tag: String; var cls: String; var attrs: [Attr]; var text: String? /* HTML já escapado, `<br>` como veio */; var children: [MarkupNode]; var layer: Layer? }`
  - `enum ExportMarkup`: `static func split(_ code: String) -> (markup: String, css: String)` (corta em `\n<style>\n` … `</style>`; sem estilo: css vazio); `static func parse(_ markup: String) throws(ProtocolError) -> [MarkupNode]` (tokens `<div class="…">`, `</div>`, `<p class="…">…</p>`, classe opcional; outra coisa → `.internal` "unexpected export markup"); `static func layer(_ json: JSONValue) -> Layer?` (lê os campos de `node_json`: `layout.mode`, `layout.gridColumns`, `layout.columnTracks`, `layout.crossGap`; `visible` ausente = true); `static func className(_ name: String, used: inout [String]) -> String` (port exato de `class_name`: minúsculas, só ASCII alfanumérico, outros viram um `-` sem repetir nem no início, corta `-` final, máx. 40, vazio ou começando por dígito → `layer-<base>`, repetido → `-2`, `-3`…); `static func attach(_ root: inout MarkupNode, _ layer: Layer) -> Bool`.
- Algoritmo de `attach` (pré-ordem, um `used` por raiz, como o `Markup` do codegen): o nó recebe `className(layer.name)`; se ≠ `cls` → falha. Filhos visíveis = `children.filter(\.visible)`. Markup sem filhos → ok (folha ou corte de profundidade do codegen). Senão a contagem tem de ser igual e cada par recursa em ordem. Falha em qualquer ponto → `false` e **nenhum** `layer` fica atribuído (trabalhar numa cópia).

- [ ] **Step 1: Testes** (com os fixtures):
  - `classNamesMatchFigcraft`: `["Card","Card","","Seção","2024","Card / Title","--x--"]` com um `used` → `["card","card-2","layer-","se-o","layer-2024","card-title","x"]`.
  - `parsesFixtureMarkup`: raiz `cls == "landing"`, `tag == "div"`; o filho de classe `title` é `p` com `text == "Hello"`; `items` tem `text == "One<br>Two"`.
  - `attachHandlesDuplicatesAndHidden`: com `node.json`, `attach` → true; o nó `card-3` tem `layer?.name == "Card"`; nenhum nó ligado a `Hidden`; `link` tem `layer?.hyperlink == "https://example.com"`; `features` tem `layoutMode == "grid"`, `gridColumns == 3`, `columnTracks.count == 3`.
  - `attachMismatchAttachesNothing`: renomeie um filho no `Layer` (`"Hero"`→`"Top"`) → false, e toda a árvore tem `layer == nil`.
- [ ] **Step 2:** rodar → FAIL. **Step 3:** implementar. **Step 4:** `swift test --filter HTMLExportTests` → PASS. **Step 5:** Commit `feat(design): map figcraft export markup to layers`.

### Task 3: Semântica (tags, listas, links) e serialização

**Files:** Create `Sources/OrqDaemonKit/Design/ExportSemantics.swift`; Test `HTMLExportTests.swift`

**Interfaces:**
- Consumes: `MarkupNode`, `Layer` (Task 2).
- Produces: `enum ExportSemantics { static func apply(_ root: inout MarkupNode, warnings: inout [String]); static func html(_ root: MarkupNode, depth: Int) -> String; static func safeHref(_ raw: String) -> String? }`.
- Regras, nesta ordem (a primeira que decide a tag vence):
  1. **Nome da camada** (primeira palavra, separadores espaço `/` `-` `:` `_`, minúsculas): camada não-texto com `header|footer|nav|main|section|article|aside` → essa tag; camada texto com `h1`…`h6`|`p` → essa tag.
  2. **Raiz** → `main`.
  3. **Filho direto da raiz** que é `div` com filhos → `section`.
  4. **Headings** (só nós com `layer`): tamanho do corpo = `fontSize` com mais caracteres somados entre os textos (empate: o menor); candidatos = textos com `fontSize >= corpo × 1.25` e `characters.count <= 200`; tamanhos distintos em ordem decrescente → `h1`, `h2`, …, `h6` (do 6º em diante `h6`).
  5. **Lista do figcraft**: `listStyle` `bulleted` → `ul`, `numbered` → `ol`; o texto vira um `li` por linha (`<br>`), sem classe nos `li`.
  6. **Parágrafos com marcador** (vale sem `layer`): em qualquer contêiner, sequência de ≥ 2 irmãos `p` consecutivos cujo texto começa com `•`, `·`, `◦`, `-`, `–`, `*` seguido de espaço → embrulhados num `ul` de classe `orq-list`, cada um vira `li` (classe e texto mantidos).
  7. **Links**: `layer.hyperlink` passa por `safeHref` → o conteúdo de `p`/`h*`/`li` vira `<a href="…">…</a>`; recusado → aviso `link dropped: <nome da camada>`.
- `safeHref`: aparar espaços; aceitar `http:`, `https:`, `mailto:`, `tel:` (sem diferenciar maiúsculas), `#…`, `/…` e relativos sem `:` antes do primeiro `/`; devolver com `&`, `"`, `<`, `>` escapados; senão `nil`.
- `html`: indentação de 2 espaços por nível; `<tag class="c">texto</tag>` (sem `class` quando vazio); atributos extras em ordem.

- [ ] **Step 1: Testes:**
  - `semanticTagsFromFixture`: depois de `attach` + `apply`, `html` contém `<main class="landing">`, `<section class="hero">`, `<h1 class="title">Hello</h1>`, `<h2 class="subtitle">Sub</h2>`, `<p class="body">Body text one</p>`, `<ul class="items">` com `<li>One</li>` e `<li>Two</li>`, `<ul class="orq-list">` com `<li class="bullet">• Alpha</li>`, `<p class="link"><a href="https://example.com">Site</a></p>`, `<footer class="footer">`.
  - `unsafeLinksDropped`: `Bad link` sai sem `<a`, e `warnings` contém `link dropped: Bad link`; `safeHref("javascript:alert(1)") == nil`, `safeHref(" https://a.b/?q=\"x\" ") == "https://a.b/?q=&quot;x&quot;"`, `safeHref("docs/a.html") == "docs/a.html"`, `safeHref("data:text/html,x") == nil`.
  - `unmappedUsesStructuralRulesOnly`: sem `attach`, `apply` → `main`, `section`, `ul.orq-list`; nenhum `<h1`, nenhum `<a`.
  - `textStaysEscaped`: um `p` com `text == "&lt;script&gt;"` sai igual.
- [ ] **Step 2–4:** FAIL → implementar → PASS. **Step 5:** Commit `feat(design): semantic html for exports`.

### Task 4: CSS (reset, fontes, temas, grid, responsivo) e documento completo

**Files:** Create `Sources/OrqDaemonKit/Design/{ExportStyles,HTMLExport}.swift`; Test `HTMLExportTests.swift`

**Interfaces:**
- Consumes: Tasks 2–3.
- Produces:
  - `struct CSSRule: Equatable, Sendable { var selector: String; var decls: [Attr] }` (`Attr.name` = propriedade).
  - `enum ExportStyles`: `static func parse(_ css: String) -> (root: [Attr], rules: [CSSRule])`; `static func themes(root: [Attr], variables: [JSONValue]) -> String`; `static func cssVarName(_ name: String) -> String` (port de `css_var_name`/`css_var_of`: `codeSyntax.WEB` quando houver); `static func adapt(_ rules: inout [CSSRule], tree: MarkupNode) -> [CSSRule] /* devolve as regras do @media */`; `static let reset: String`; `static func fallback(_ family: String) -> String`.
  - `struct ExportAsset: Sendable, Equatable { var id: String; var name: String; var kind: String /* icon|image */; var data: Data }`
  - `struct ExportInput: Sendable { var title: String; var code: [String] /* um por raiz */; var layers: [JSONValue] /* get_node por raiz */; var variables: [JSONValue] /* variable.list da tela, depois do design system ativo */; var assets: [ExportAsset] }`
  - `struct ExportBundle: Sendable { var html: String; var files: [(path: String, data: Data)]; var warnings: [String] }`
  - `enum HTMLExport { static func build(_ input: ExportInput) -> ExportBundle }`
- Valores fixos:
  - `reset` (exato):
    ```css
    *, *::before, *::after { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; }
    h1, h2, h3, h4, h5, h6, p, ul, ol, li, figure { margin: 0; padding: 0; }
    ul, ol { list-style-position: inside; }
    ul.orq-list { list-style: none; }
    a { color: inherit; }
    img, svg { display: block; max-width: 100%; height: auto; }
    ```
  - `fallback`: família com `mono` (sem diferenciar maiúsculas) → `ui-monospace, SFMono-Regular, Menlo, monospace`; senão `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`. Toda `font-family: "X"` vira `font-family: "X", <fallback>`. Sem `@font-face` (nada de rede; fontes locais do usuário valem).
  - **Temas:** só variáveis presentes no `:root` do export. Para cada coleção com ≥ 2 modos, cada modo vira `[data-theme="<slug do nome>"] { … }` (slug: minúsculas, não-alfanumérico → `-`); valores no formato do `:root` (cor → `#RRGGBB`, ou `#RRGGBBAA` se alfa < 1, maiúsculas; o `:root` com `px` → `<n>px`; senão o número); alias (`{type: alias, id}`) resolvido pelo modo de mesmo nome na coleção alvo, senão o primeiro modo, até 8 saltos. Mesmo nome CSS vindo de mais de uma lista: **a última vence** (o design system ativo vem depois). Havendo modo chamado `dark` (slug): `@media (prefers-color-scheme: dark) { :root:not([data-theme]) { …valores dark… } }`. O `:root` do export fica como veio.
  - **Grid** (camada `layoutMode == "grid"`): na regra dela, `display: flex` → `display: grid`; remover `flex-direction`, `flex-wrap`, `align-content`; `gap: V` → `column-gap: V` + `row-gap: <crossGap>px`; acrescentar `grid-template-columns:` com `max(gridColumns,1)` trilhas (`fixed` → `<v>px`, `fill` → `<v>fr`, `hug` → `auto`, faltando → `1fr`).
  - **Responsivo:** regra da raiz: `width: Npx` → `width: 100%` + `max-width: Npx` + `margin: 0 auto`; `height: Npx` → `min-height: Npx`. Qualquer regra com `align-self: stretch` perde `width`; com `flex: 1 1 0` perde `width` e ganha `min-width: 0`; texto (`p`, `h*`, `li`, `ul`, `ol`) com `width` sem stretch → `max-width`. `@media (max-width: 640px)`: regra com `flex-direction: row` ganha `flex-wrap: wrap`; grid ganha `grid-template-columns: 1fr`.
  - **Assets:** `icon` → o nó perde os filhos e o `background` da regra; o SVG (sem `<?xml…?>`) entra inline no nó. SVG com `<script`, `foreignObject`, `javascript:` ou atributo `on…=` → grava `assets/<slug>-<id>.svg` e o nó vira `<img src alt>` (aviso). `image` → nó sem filhos vira `<img class src="assets/<slug>-<id>.png" alt="<nome escapado>">`, a regra troca `background: url(image.png) …` por `object-fit: cover`; nó com filhos: só remove o `background` com `url(image.png)` e avisa `background image not exported: <nome>`. `<slug>` = `className` do nome do asset sem extensão.
  - **Várias raízes** (export da página): a raiz `k ≥ 1` (0-based) tem toda classe `c` renomeada `r<k+1>-c` no markup e nas regras; `:root` mesclados (primeira ocorrência vence).
  - **Documento** (exato, `title` escapado):
    ```html
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="generator" content="Orq">
    <title>{title}</title>
    <style>
    {reset}{:root}{temas}{regras}{@media}</style>
    </head>
    <body>
    {markup}</body>
    </html>
    ```
  - Raiz cujo `attach` falhou → aviso `layer map mismatch: <nome da raiz>` (só regras estruturais, Task 3).

- [ ] **Step 1: Testes** (`build` com os fixtures; `assets` montados de `export-files.json` × `assets.json`):
  - `buildsCompleteDocument`: começa com `<!doctype html>`; tem `<meta name="viewport"`, `<title>Landing</title>`, o `reset`; `font-family: "Inter", system-ui`; nenhum `http` além de `https://example.com` e do namespace SVG.
  - `themesFromVariables`: tem `[data-theme="light"]` com `--color-bg: #FAFAF7` e `[data-theme="dark"]` com `--color-bg: #111317` e `--color-text: #ECEDEF`; `@media (prefers-color-scheme: dark)`; `--space-m` nos dois modos como `16px`. Com uma segunda lista de variáveis em que `color/bg` Dark = `#000000`, o dark sai `#000000`.
  - `gridAndResponsive`: regra `.features` tem `display: grid`, `grid-template-columns: 1fr 1fr 200px`, sem `flex-direction`; `.landing` tem `max-width: 800px` e `width: 100%`; `.title` (stretch) sem `width:`; `@media (max-width: 640px)` com `.features { grid-template-columns: 1fr; }`.
  - `assetsInlinedOrFiled`: `<svg` dentro do nó `icon-star`; `<img class="photo" src="assets/photo-` e um arquivo `assets/photo-<id>.png` em `files`; regra `.photo` sem `url(image.png)`.
  - `unsafeSVGBecomesImg`: asset icon com `<svg onload="x()">` → `<img` + arquivo `.svg` + aviso.
  - `pageWithTwoRootsPrefixesClasses`: `code` = [fixture, fixture] → a segunda raiz usa `r2-landing`, sem regra duplicada `.landing`.
- [ ] **Step 2–4:** FAIL → implementar → PASS. **Step 5:** Commit `feat(design): complete html documents from figcraft exports`.

### Task 5: Snapshot do motor (chamador e daemon) + carimbo

**Files:** Modify `Sources/OrqDaemonKit/Design/DesignService.swift`, `Tests/Fixtures/fake-figcraft-mcp.py`; Test `Tests/OrqDaemonKitTests/DesignCommandTests.swift`

**Interfaces:**
- Consumes: `ExportAsset` (Task 4); `use`, `onSystemClient`, `sync`, `topLayers`, `scrub` (2A).
- Produces:
  - `struct ExportSnapshot: Sendable { var code: [String]; var layers: [JSONValue]; var variables: JSONValue; var assets: [ExportAsset]; var thumbnail: Data?; var stamp: String }`
  - `static func snapshot(_ c: MCPStdioClient, node: String?, deadline: ContinuousClock.Instant) async throws(ProtocolError) -> ExportSnapshot`: `sync`; raízes = `node` ou `topLayers` (vazio → `.invalidArgs` "the page is empty: nothing to export"); por raiz `get_node {id, depth: 64}` e `inspect.code {id, language: html}`; `variable.list`; `inspect.assets {ids: raízes}`; havendo `icon`/`image`, `file.exportLayers {ids: raízes, assets: true}` (sem `dir`) e casar por `id` com os kinds; miniatura = `screenshot {ids: [primeira raiz]}` (falha → `nil`); tudo que é texto passa pelo scrubber.
  - `static func stamp(layers: [JSONValue], variables: JSONValue) -> String`: SHA-256 hex do JSON canônico (`sortedKeys`) de `[layers sem "absoluteBounds" em qualquer nível e sem "x"/"y" das raízes, variables]`.
  - `func htmlSnapshot(panel: Panel, caller: (key: String, name: String), node: String?) async throws -> (file: File, snapshot: ExportSnapshot)` — cliente do chamador (caminho de `design.export`); `try alive(panel)` depois.
  - `func systemSnapshot(fileId: String, node: String?, deadline: ContinuousClock.Instant) async throws -> ExportSnapshot` e `func currentStamp(fileId: String, node: String?, deadline: ContinuousClock.Instant) async throws -> String` (só `get_node`/`inspect_document` + `variable.list`) — cliente do daemon.
  - `func variables(ofFile id: String, deadline: ContinuousClock.Instant) async throws -> JSONValue` — `variable.list` pelo cliente do daemon (arquivo do design system ativo).
  - `func file(named:)`/`func file(id:)` públicos o bastante para o router (já existe `file(_:)` privado: expor `fileRecord(_ id: String) throws -> File`).
- Fake: `get_node` com `id == <id da raiz do fixture>` → `node.json`; `inspect.code` com esse id → `code.html`; `variable.list` → `variables.json`; `inspect.assets` → `assets.json`; `file.exportLayers` → `export-files.json`; outros ids mantêm as respostas antigas. Caminho dos fixtures: `os.path.realpath(__file__)` → `html-export/`.

- [ ] **Step 1: Testes:** `snapshotCollectsEverything` (fake, painel de doca, `node` = raiz do fixture: 1 code, 1 layer, 2 assets, thumbnail PNG, stamp 64 hex) e `stampIgnoresPositionOnly` (mesma árvore com raiz `x` e todos `absoluteBounds` mudados → mesmo stamp; `characters` mudado → outro).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter DesignCommandTests`). **Step 5:** Commit `feat(design): export snapshots and design stamps`.

### Task 6: Registro de artifacts + `design.export --format html` vira artifact

**Files:** Create `Sources/OrqDaemonKit/Artifacts/ArtifactStore.swift`, `Sources/OrqDaemonKit/ArtifactCommands.swift`, `Tests/OrqDaemonKitTests/ArtifactTests.swift`; Modify `Sources/OrqDaemonKit/{CommandRouter,DesignCommands,Daemon}.swift`, `Tests/OrqDaemonKitTests/DesignCommandTests.swift`

**Interfaces:**
- Consumes: `HTMLExport.build`, `ExportSnapshot`, `htmlSnapshot`, `variables(ofFile:)`, `activeSystem(floor:)`, `systems.list()`, `origin(_:)`, `pluginEmitted`.
- Produces:
  - `struct Artifact: Codable, Sendable, Equatable { enum Kind: String, Codable, Sendable { case export, agent }; var id: UUID; var kind: Kind; var title: String; var fileId: String?; var node: String?; var floorId: UUID?; var by: String; var at: Date; var version: Int; var folder: String /* relativo a <root>/artifacts */; var stamp: String?; var warnings: [String] }`
  - `actor ArtifactStore { init(root: URL); func list() throws -> [Artifact]; func get(_ id: UUID) throws -> Artifact; func newVersion(fileId: String, node: String?, title: String, floorId: UUID?, by: String) throws -> (Artifact, URL /* pasta nova vazia */); func commit(_ a: Artifact) throws; func addAgent(source: URL, title: String, floorId: UUID?, by: String) throws -> Artifact; func remove(_ id: UUID) throws }`
  - Layout: `<root>/artifacts/artifacts.json` (0600, escrita atômica, `DesignService.writePrivate`); export = um artifact por `(fileId, node)` (`node` nil = página), versão `N` em `<id>/v<N>/` com `index.html`, `assets/…`, `thumb.png`; `newVersion` reserva `N` dentro do actor (dois exports concorrentes → `v1`, `v2`) e só `commit` grava o registro (pasta órfã sem commit é ignorada). Agente = `<id>/source.html` (0444). `remove` move `<id>/` para `.removed/<id>-<epochMs>/` e tira do registro.
  - `func exportHTML(_ f: DesignService.File, node: String?, snapshot: ExportSnapshot, by: String) async throws -> JSONValue` no router: variáveis = `[snapshot.variables] + [variáveis do arquivo do design system ativo no andar do arquivo, se houver e não for o próprio arquivo]` (erro ao ler o do design system → segue sem e aviso `design system tokens unavailable`); `title` = nome da raiz (com `node`) ou nome do arquivo; grava `index.html`, `files`, `thumb.png` (offPool); `commit` com `stamp`, `warnings`; emite `artifact.exported` (`{id, version}`) para todo painel `artifacts`; devolve `{path: <…/index.html>, artifact: <id>, version, warnings}`.
  - `design.export --format html` no `designCommand`: `htmlSnapshot` + `exportHTML` (as outras formats ficam como estão no 2A).

- [ ] **Step 1: Testes:**
  - `htmlExportBecomesArtifact` (fake): `design.export --format html --node <raiz>` → `path` termina em `/artifacts/<id>/v1/index.html`, arquivo começa com `<!doctype html>`, `thumb.png` existe, `assets/` com o PNG; segundo export → mesmo `artifact`, `version == 2`, `v1/` intacta.
  - `concurrentExportsGetDistinctVersions`: dois `design.export` html simultâneos → versões `{1, 2}`.
  - `exportUsesActiveSystemTokens`: com um design system ativo (fake), o export chama `variable.list` no arquivo do sistema (log do fake) e o `index.html` tem `[data-theme="dark"]`.
  - Atualizar `screenshotAndExportWriteUnderRoot`: html agora sob `artifacts/`; css/react/figcraft continuam em `design/exports/<fid>/`.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "ArtifactTests|DesignCommandTests"`). **Step 5:** Commit `feat(artifacts): versioned html export artifacts`.

### Task 7: Comandos `artifact.*` e plug-in de doca

**Files:** Modify `Sources/OrqDaemonKit/ArtifactCommands.swift`, `Sources/OrqDaemonKit/CommandRouter.swift`, `Sources/OrqProtocol/Plugins.swift`; Test `ArtifactTests.swift`, `Tests/OrqProtocolTests` (lista de comandos, se houver teste de catálogo)

**Interfaces:**
- Produces: `PluginRegistry.artifacts = PluginSpec(id: "artifacts", title: "Artifacts", placements: [.dockRight, .dockLeft, .dockBottom], defaultPlacement: .dockRight, commands: […], events: ["artifact.exported", "artifact.added"], runsInDaemon: true)`; o router despacha `plugin.id == "artifacts"` para `artifactCommand(_:peer:)` (principal admin ou terminal, como `memory.*`).
- Comandos (`timeout` entre parênteses):
  - `artifact.list` (60): `[{id, kind, title, file /* nome do arquivo ou null */, node, by, at, version, url, path, thumbnail /* caminho ou null */, status, warnings}]`, mais novo primeiro. `status`: `export` → `current`|`stale` (carimbo atual ≠ guardado)|`missing` (arquivo fora do registro, ou o motor responde `no such layer <id>`)|`unknown` (outro erro/prazo); `agent` → `pending`. Carimbos por `currentStamp`, agrupados por arquivo, sequenciais, cada um com prazo próprio de 10 s, todos dentro do prazo do comando. `url` = `orq-artifact://app/<folder>/index.html` (agente: `orq-artifact://app/<id>/source.html`).
  - `artifact.get <id>` (10): o item como acima, sem `status`.
  - `artifact.add --path <arquivo> [--title]` (30): agente ou app. Caminho relativo ao `cwd`; precisa ser arquivo regular (sem seguir symlink: `lstat`), extensão `.html`/`.htm`, ≤ 8 MiB; título padrão = nome do arquivo. `by` = `origin(caller)`, `floorId` = andar do chamador. Emite `artifact.added`. Devolve `{id}`.
  - `artifact.reexport <id>` (120): **só app**; `export` → `systemSnapshot` + `exportHTML` (nova versão); `agent` → `.invalidArgs` "imported in plan 2D"; arquivo sumido → `.notFound`.
  - `artifact.remove <id>` (10): **só app**.
  - Terminal chamando reexport/remove → `.unauthorized` "'artifact.reexport' is for the app only".

- Fake (estende o do Task 5): `node.set` com `characters` muda o `characters` do primeiro texto da árvore do fixture (o `get_node` seguinte reflete); `edit.delete` com `ids` contendo a raiz do fixture → dali em diante `get_node` dela responde erro `no such layer <id>`; `run_command` `node.slowreads` → dali em diante `get_node` dorme 30 s. (Esse estado é por processo do fake: o cliente do daemon é outro processo, então o fake guarda o estado num arquivo ao lado de `ORQ_FAKE_FIG_LOG`.)

- [ ] **Step 1: Testes:**
  - `agentRegistersHTML`: terminal `artifact.add --path site/index.html` (cwd tmp) → `artifact.list` mostra `kind == "agent"`, `status == "pending"`, `by` com o nome do terminal; `source.html` com o conteúdo e modo 0444.
  - `addRefusesSymlinkNonHTMLAndHuge`: symlink → `.invalidArgs`; `.txt` → `.invalidArgs`; 9 MiB → `.invalidArgs`.
  - `listMarksCurrentAndStale`: export → `current`; `design.run node.set` muda `characters` (fake muda a resposta de `get_node`) → `stale`; `artifact.reexport` (admin) → `version == 2`, `current`.
  - `listMarksMissingAndUnknown`: exportar a raiz, `design.run edit.delete` nela → `missing`; noutro daemon, exportar, `design.run node.slowreads` → `unknown`, e a lista responde em < 60 s.
  - `reexportAndRemoveAreAppOnly`: terminal → `.unauthorized`; app `remove` → some da lista, pasta em `.removed/`.
- [ ] **Step 2–4:** FAIL → implementar → PASS. **Step 5:** Commit `feat(artifacts): artifact commands and dock plugin`.

### Task 8: Navegador abre artifacts + painel Artifacts

**Files:** Create `Sources/OrqPlugins/ArtifactsPanel.swift`, `Tests/OrqPluginsTests/ArtifactsPanelTests.swift`; Modify `Sources/OrqPlugins/BrowserPanel.swift`, `Sources/OrqApp/OrqApp.swift`, `Tests/OrqPluginsTests/BrowserAutomationTests.swift` (ou o arquivo de testes do Navegador existente)

**Interfaces:**
- Consumes: `artifact.*` (Task 7), `panel.open` (`plugin`, `name`, `url`, `file`), `browser.navigate`, `DesignSchemeHandler` (serve uma pasta, GET, sem sair dela).
- Produces (Navegador): `static let artifactScheme = "orq-artifact"`; a configuração registra `DesignSchemeHandler(root: host.root.appendingPathComponent("artifacts"))` para esse esquema; `url(_:)` aceita `orq-artifact://app/…`; `allowsNavigation(to:from:appLoad:) -> Bool`: esquemas web como hoje; `orq-artifact` só se a origem também é `orq-artifact`, ou é `about:blank`/nil, ou é a carga pedida pelo app/agente (`appLoad == url`, guardado antes de `web.load`). Página web navegando para `orq-artifact://` → cancelada.
- Produces (painel): `public struct ArtifactRow: Decodable, Identifiable, Equatable, Sendable { id, kind, title, file?, node?, by, at: Date, version, url, thumbnail?, status?, warnings }`; `@MainActor public final class ArtifactsModel: ObservableObject { rows, error, busy; init(call:); refresh() async /* artifact.list */; openInBrowser(_:) async; openInDesign(_:) async; reexport(_:) async; remove(_:) async }`; `ArtifactsPanel: PluginPanelView` (SwiftUI em `NSHostingView`), registrado como `"artifacts"`.
- Comportamento:
  - Lista ao abrir e no botão **Atualizar** (eventos de plug-in para o app seguem adiados): miniatura (64 pt de altura, `NSImage(contentsOfFile:)`; agente: ícone de documento), título, origem (`tela <file>` ou `HTML do agente`), `por <by> · <data relativa>`, `v<version>`, selo de status (`atual`, `desatualizado`, `origem removida`, `desconhecido`, `aguardando importação`), avisos num `help`.
  - **Abrir no Navegador:** `browser.navigate {panel: "Prévia", url}`; `notFound` → `panel.open {plugin: "browser", name: "Prévia", url}`.
  - **Abrir no Design** (só export com `file`): `panel.open {plugin: "design", file}`.
  - **Reexportar** (só export): `artifact.reexport`, depois `refresh`.
  - **Remover:** `confirmationDialog` SwiftUI "Remover <título>? A pasta vai para artifacts/.removed." → `artifact.remove`.

- [ ] **Step 1: Testes:**
  - `artifactSchemeServesOnlyArtifacts`: `DesignSchemeHandler(root: <tmp>/artifacts)` serve `orq-artifact://app/<id>/v1/index.html` (200, `text/html`) e recusa `orq-artifact://app/../secret.txt` e `%2e%2e` (404).
  - `navigationRules`: `allowsNavigation(to: orq-artifact…, from: https://x, appLoad: nil) == false`; `from: orq-artifact…` → true; `appLoad == url` → true; `url("orq-artifact://app/a/v1/index.html")` não lança; `url("file:///etc")` lança.
  - `modelOpensBrowserThenFallsBack` (call falso grava as chamadas): `browser.navigate` → `notFound` → `panel.open` com `plugin: browser`, `name: Prévia`, mesma `url`.
  - `modelOpensDesignAndReexports`: `openInDesign` → `panel.open {plugin: design, file: "Site"}`; `reexport` → `artifact.reexport` e depois `artifact.list`.
  - `rowsDecodeStatuses`: JSON de `artifact.list` com os 5 status → `rows` com os rótulos em português.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "ArtifactsPanelTests|Browser"`). **Step 5:** Commit `feat(artifacts): artifacts panel and browser preview`.

### Task 9: Ida e volta com o motor real + docs

**Files:** Modify `Tests/OrqDaemonKitTests/DesignCommandTests.swift` (dentro da suíte `.serialized`), `README.md`, `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`; Create (scratchpad, fora do repo) a checklist humana `plan2c-checklist-visual.md`

**Interfaces:** Consumes tudo acima.

- [ ] **Step 1: Teste** `realEngineHTMLArtifact` (`.enabled(if: realBuilt)`, `.timeLimit(.minutes(3))`): Maestro com painel Design; `design.batch --file Tests/Fixtures/html-export/doc.json` (o mesmo documento do Task 1; trocar o caminho do `image.place` por um PNG gravado no `cwd` permitido, ou pular a imagem se o `image.place` com caminho for recusado a agentes — então esperar só o ícone); `design.export --format html --node <raiz>` → `index.html` contém `<h1`, `<ul class="items">`, `<a href="https://example.com">`, `[data-theme="dark"]`, `display: grid`, `<svg`; `artifact.list` → `current`; `design.run node.set {ids:[título], characters: "Changed"}` → `stale`; `artifact.reexport` (admin) → `version 2`, `current`.
- [ ] **Step 2:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → tudo verde (anotar contagem).
- [ ] **Step 3:** README: seção Artifacts (comandos, onde ficam, `orq-artifact://`, limitações). Roteiro: linha 2C → `✅ 2026-10-22-plan-2c-artifacts-export.md (merged)` só no merge; aqui, "em execução". Checklist humana no scratchpad (passos visuais: exportar o portfólio, abrir no Navegador, alternar `data-theme` pelo console, mudar o design e ver "desatualizado", reexportar, registrar HTML de agente, remover).
- [ ] **Step 4:** Commit `test(artifacts): real engine round trip; docs`.

---

## Fora deste plano (anotar no README como limitações)

- Importar HTML de agente como tela (o artifact fica `pending`): **2D**.
- Painel não atualiza sozinho com eventos (entrega de `pluginEvent` ao app segue adiada): botão Atualizar.
- Fontes não vão embutidas no export (fallback do sistema); links só de camada inteira (trechos com link dentro do texto saem sem `<a>`); fundo-imagem de frame com filhos não é exportado.
- Todos os artifacts compartilham a origem `orq-artifact://app` no Navegador (HTML de agente pode ler outros artifacts locais).
