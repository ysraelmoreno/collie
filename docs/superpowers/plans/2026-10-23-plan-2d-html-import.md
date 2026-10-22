# Plano 2D — Importar HTML como tela — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Todo HTML registrado por agente (`artifact.add`) é renderizado num WKWebView invisível do app, lido do DOM (caixas e estilos computados) e recriado como **nova tela** num arquivo de design novo, num único `batch` do figcraft (um passo de desfazer); o artifact passa a ser o export dessa tela, com o HTML original arquivado como origem somente leitura.

**Architecture:** O daemon não tem WebKit: pede ao app, pelo canal `ui.host` já existente, um **snapshot do DOM** (`html.snapshot`) endereçado a um alvo reservado (não a um painel). O app carrega a página pelo esquema `orq-artifact://` (2C) num WKWebView fora da tela, com **rede bloqueada** e dados não persistentes, e roda um script de extração que devolve uma árvore JSON. Um **mapeador Swift puro** (`HTMLImport`) converte a árvore em passos do figcraft (flex → auto layout, grid → grid, resto → posição absoluta, texto com trechos estilizados, imagens por `image.place {data}`, SVG por `file.import {data}`); o daemon cria o arquivo, roda o lote no cliente dele e reaproveita o export do 2C no mesmo artifact.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, WebKit (`WKWebView`, `WKContentRuleList`, `WKWebsiteDataStore.nonPersistent()`), JavaScript de extração embutido; figcraft v0.7.0 do 2A (+ patch 0003). Nenhuma dependência nova.

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.1.1 (importar HTML), §7.3 (Artifacts), §7.1 (design é fonte da verdade), §6 (cordas). Roteiro: `docs/superpowers/plans/2026-10-20-phase2-roadmap.md` (2D). Base: `main` em `6fdc241` (2A+2B+2C mergeados: `ArtifactStore`, `artifact.*`, `exportHTML`, esquema `orq-artifact`, `DesignService.onSystemClient`).

## Global Constraints

- **Design é a fonte da verdade** (spec §7.1): depois de importar, a tela do design é a oficial; o HTML original fica arquivado como "origem" (somente leitura); edições posteriores passam pelo design (spec §7.1.1).
- Abordagem fixada pela spec §7.1.1: "renderizar o HTML num WKWebView invisível, ler caixas e estilos computados do DOM, mapear flex → auto layout, texto → text nodes, imagens/SVG → fills/vetores, e criar os frames via comandos do figcraft em lote (um passo de desfazer)". Resultado **aproximado; aceitável**.
- HTML de agente entra **só pelo comando de artifact** e **dispara a importação** (spec §7.3).
- **Nada sai da máquina:** o WKWebView de importação bloqueia toda carga de rede (`http`, `https`, `ws`, `wss`, `ftp`); só `orq-artifact://` e `data:`/`blob:` carregam. Recursos bloqueados viram aviso.
- **Corda é a única permissão:** `artifact.import` segue a regra de doca do 2C (qualquer terminal ou o app); o arquivo de design novo nasce no andar de quem registrou. O lote roda no cliente do daemon com passos **gerados pelo mapeador** (nunca texto do agente repassado como comando).
- Segredos do 2A: nada de link/chave em resultado, aviso ou arquivo; erros passam pelo scrubber.
- Nada é apagado sem o usuário; reimportar cria outro arquivo de design, o anterior fica.
- Nada de I/O bloqueante no pool cooperativo; WebKit só no `MainActor`; protocolo `v: 1`; textos de UI em português; testes com fakes + WebKit real (app) + build real do figcraft (gated `realBuilt`, na suíte `.serialized` de design).

## Review Focus

1. **Página que depende de rede** (fonte do Google, imagem de CDN, script remoto) → nada é buscado; a página importa com o que tem localmente; avisos listam os recursos bloqueados. Teste: Task 1 `networkIsBlocked`.
2. **Página enorme ou patológica** (milhares de nós, imagem de 50 MB, SVG gigante, altura 100000 px, script em loop) → snapshot para no limite (`truncated` + aviso), imagens/SVG acima do teto viram retângulo cinza com aviso, prazo de 30 s; nunca trava o app. Teste: Task 1 `capsAndTimeout`.
3. **App fechado / host trocado no meio** → `artifact.add` registra e o artifact fica `failed` com "Orq app is not running"; `artifact.import` refaz depois. Teste: Task 4 `importWithoutAppFails`.
4. **Fonte que o motor não tem / peso que a família não tem** → usa a família do motor de mesmo nome (sem diferenciar maiúsculas) e o estilo mais próximo; sem família, Inter, com aviso por família. Teste: Task 2 `fontsFallBackWithWarning`.
5. **HTML hostil** (`javascript:` em `href`, `<svg onload>`, texto com `<script>`, nome de classe com aspas) → link descartado com aviso, SVG importado como dados (o figcraft não executa nada), texto entra como texto literal; nada vira comando além dos que o mapeador gera. Teste: Task 2 `hostileContentStaysData`.

---

## File Structure

```
Sources/OrqProtocol/HostTarget.swift                 alvo reservado do ui.host (importador)
Sources/OrqDaemonKit/PluginHost.swift                (+ callApp)
Sources/OrqPlugins/HTMLSnapshotter.swift             WKWebView fora da tela, rede bloqueada, extração
Sources/OrqPlugins/HTMLSnapshotScript.swift          o JavaScript de extração (string)
Sources/OrqApp/OrqApp.swift                          handler: alvo reservado → HTMLSnapshotter
Sources/OrqDaemonKit/Design/HTMLImport.swift         DOMSnapshot (Codable) → passos do figcraft (puro)
Sources/OrqDaemonKit/Artifacts/ArtifactStore.swift   (+ source, importError, pasta de origem, converter em export)
Sources/OrqDaemonKit/ArtifactImport.swift            orquestração: snapshot → arquivo novo → batch → export
Sources/OrqDaemonKit/ArtifactCommands.swift          (+ artifact.import, add --root, add dispara import)
Sources/OrqProtocol/Plugins.swift                    (+ artifact.import, param root)
Sources/OrqPlugins/ArtifactsPanel.swift              (+ importing/failed, Abrir origem, Importar de novo)
Tests/Fixtures/html-import/landing/{index.html,style.css,logo.svg,hero.png}, Tests/Fixtures/html-import/landing.snapshot.json
Tests/OrqPluginsTests/HTMLSnapshotterTests.swift, Tests/OrqDaemonKitTests/{HTMLImportTests,ArtifactImportTests}.swift
Tests/Fixtures/fake-figcraft-mcp.py                  (+ file.import, image.place, text.fonts, batch com ids)
README.md, docs/superpowers/plans/2026-10-20-phase2-roadmap.md
```

---

### Task 1: Snapshot do DOM no app (WKWebView fora da tela, rede bloqueada)

**Files:** Create `Sources/OrqProtocol/HostTarget.swift`, `Sources/OrqPlugins/{HTMLSnapshotter,HTMLSnapshotScript}.swift`, `Tests/OrqPluginsTests/HTMLSnapshotterTests.swift`, `Tests/Fixtures/html-import/landing/*`, `Tests/Fixtures/html-import/landing.snapshot.json`; Modify `Sources/OrqDaemonKit/PluginHost.swift`, `Sources/OrqApp/OrqApp.swift`

**Interfaces:**
- Produces: `public enum HostTarget { public static let importer = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")! }`; `PluginHost.callApp(command: String, args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue` (mesmo `call`, com o alvo reservado); no app, o `panelHandler` desvia `panel == HostTarget.importer` para `HTMLSnapshotter.handle(command:args:)` (só `html.snapshot`; outro comando → `.invalidArgs`).
- Produces: `@MainActor public enum HTMLSnapshotter { static func snapshot(url: URL, artifactsRoot: URL, width: Int, timeout: Duration) async throws(ProtocolError) -> JSONValue }`. `html.snapshot {url, width}`: `url` só `orq-artifact://app/…` (outra coisa → `.invalidArgs`), `width` 320…3840 (padrão 1440). `artifactsRoot` = `host.root/artifacts`.
- WKWebView: frame `width × 900`, fora de qualquer janela; `websiteDataStore = .nonPersistent()`; `DesignSchemeHandler(root: artifactsRoot, artifacts: true)` para `orq-artifact`; `WKContentRuleList` que bloqueia `^(https?|wss?|ftp):` (registrar avisos: o script lê `performance.getEntriesByType("resource")` e as falhas de `img`/`link`); JS da página **ligado**; espera `didFinish` + `document.fonts.ready` + 300 ms; prazo total `timeout` (30 s pelo daemon). Depois roda o script (`evaluateJavaScript` no `.defaultClient`) e devolve o JSON; o WKWebView é descartado.
- Formato do snapshot (o script produz; chaves exatas):
  - `{title, width, height, truncated, blocked: [url], root}`; `height` = `scrollHeight` limitado a 20000.
  - Nó: `{tag, x, y, w, h, style, children}` + opcionais `text` (folha de texto), `runs` `[{start, end, color?, fontWeight?, fontStyle?, decoration?, href?}]`, `href`, `image {data /* base64 PNG */, w, h, fit /* cover|contain|fill */}`, `svg` (outerHTML), `alt`, `id`, `cls` (primeira classe). Coordenadas = página inteira (CSS px, `getBoundingClientRect` + `scrollX/Y`).
  - `style` só com valores **não padrão** destas propriedades computadas: `display, position, flexDirection, flexWrap, justifyContent, alignItems, rowGap, columnGap, gridTemplateColumns, paddingTop, paddingRight, paddingBottom, paddingLeft, backgroundColor, backgroundImage, color, fontFamily, fontSize, fontWeight, fontStyle, lineHeight, letterSpacing, textAlign, textDecorationLine, textTransform, borderTopWidth…Left, borderTopColor…Left, borderTopStyle, borderTopLeftRadius…BottomLeft, boxShadow, opacity, overflow, objectFit`.
  - Folha de texto: elemento cujos filhos são só texto e elementos `display: inline` (sem `img`/`svg`); `text` = `innerText`; cada inline com cor/peso/estilo/decoração/link diferentes vira um `run` (offsets em UTF-16 do `text`). `button`, `input` (value ou placeholder) e `textarea` também são folhas.
  - Pula: `display:none`, `visibility:hidden`, `w == 0 || h == 0` sem filhos visíveis, `script/style/noscript/template/head/meta/link`.
  - `img` e `background-image: url(…)` mesma origem → desenhados num `canvas` → PNG base64; acima de 4 MiB cada ou 24 MiB no total → sem `image` (o mapeador põe retângulo cinza). `svg` acima de 256 KiB → sem `svg`.
  - Limite de 3000 nós → `truncated: true`, para de descer.
- Fixture `landing/` (original, sem marca alheia, sem dados pessoais): `index.html` + `style.css` + `logo.svg` + `hero.png` (PNG 64×40 gerado); header flex row (logo SVG, 3 links `<a href="#…">`), hero (h1 48px "Construa telas com seus agentes", p com `<strong>` e `<a href="https://example.com">`, botão com fundo/raio/padding, `<img src="hero.png">`), seção de 3 cards em `grid-template-columns: repeat(3, 1fr)` com fundo, borda 1px, raio 12px e `box-shadow`, um `ul` com 3 `li`, rodapé; `<link href="https://fonts.googleapis.com/css2?family=Archivo">` e `<img src="https://example.com/remote.png">` (devem ser bloqueados); um `<script>` que troca o texto do rodapé para "carregado por script".

- [ ] **Step 1: Testes** (WebKit real, `@MainActor`, servindo `landing/` por uma pasta temporária `artifacts/<id>/source/`):
  - `snapshotsLanding`: `root.w == 1440`; existe nó `tag == "h1"` com `text == "Construa telas com seus agentes"` e `style.fontSize == "48px"`; o header tem `style.display == "flex"`; a seção de cards tem `style.display == "grid"` e 3 filhos; o `img` local tem `image.data` decodificável como PNG 64×40; o logo tem `svg` começando com `<svg`; o parágrafo do hero tem `runs` com um `fontWeight == "700"` e um `href == "https://example.com"`; o rodapé diz "carregado por script".
  - `networkIsBlocked`: `blocked` contém `https://fonts.googleapis.com/…` e `https://example.com/remote.png`, e o `img` remoto não tem `image`.
  - `capsAndTimeout`: página gerada com 5000 `div` → `truncated == true` e ≤ 3000 nós; página com `while(true){}` → `.timeout` em ≤ prazo + 2 s, sem travar o teste seguinte.
  - `refusesOtherSchemes`: `url` `https://…` ou `file:///…` → `.invalidArgs`.
  - `hostCallReachesImporter`: `PluginHost.callApp` com um host falso (padrão dos testes de `PluginHostTests`) manda `call` com `panel == HostTarget.importer`.
- [ ] **Step 2:** Gravar `landing.snapshot.json` (saída do `snapshotsLanding`, formatada, com `data` das imagens mantido) para os testes do Task 2 — por um teste marcado `.disabled` que o implementador roda uma vez, ou um script em `scripts/`; documentar no topo do arquivo de testes como regenerar.
- [ ] **Step 3–5:** FAIL → implementar → PASS (`swift test --filter "HTMLSnapshotterTests|PluginHostTests"`). Commit `feat(import): DOM snapshots in an offscreen web view`.

### Task 2: Mapeador puro DOM → passos do figcraft

**Files:** Create `Sources/OrqDaemonKit/Design/HTMLImport.swift`, `Tests/OrqDaemonKitTests/HTMLImportTests.swift`

**Interfaces:**
- Consumes: formato do snapshot (Task 1); `ExportSemantics.safeHref` (2C).
- Produces: `struct DOMSnapshot: Decodable, Sendable { … }` e `struct DOMNode: Decodable, Sendable { … }` (chaves do Task 1; `style: [String: String]`); `struct FontBook: Sendable { var families: [String: [String]] /* família → estilos, como o motor lista */ }`; `enum HTMLImport { static let maxLayers = 3000; static func steps(_ s: DOMSnapshot, fonts: FontBook, name: String) -> (steps: [JSONValue], warnings: [String]) }`. O passo 0 cria o frame raiz (o id dele = `{"$step": 0}`).
- Regras (exatas):
  - **Raiz:** `node.create {type: frame, name, x: 0, y: 0, width: s.width, height: s.height, props: {fills: [cor de fundo do body, senão do html, senão #FFFFFF], clip: true}}`. Filhos da raiz posicionados como "outros contêineres".
  - **Nome da camada:** `#id`, senão `.cls`, senão `tag`; folha de texto: os primeiros 40 caracteres do texto.
  - **Flex** (`display` `flex`/`inline-flex`): frame com `layout` `horizontal` (`row`, `row-reverse`) ou `vertical`; `gap` = `columnGap` (horizontal) ou `rowGap` (vertical), `normal` → 0; `wrap` se `flexWrap` `wrap`; `crossGap` = o outro gap; `padding` [t,r,b,l]; `mainAlign`: `flex-start|start|normal|left` → `min`, `center` → `center`, `flex-end|end|right` → `max`, `space-between|space-around|space-evenly` → `spaceBetween|spaceAround|spaceEvenly`; `crossAlign`: `stretch|normal|flex-start|start` → `min`, `center`, `flex-end|end` → `max`, `baseline`. Filhos no fluxo com `sizingH: fixed`, `sizingV: fixed` e o tamanho do retângulo; filho `position: absolute|fixed` → `absolute: true` + `x,y` relativos.
  - **Grid** (`display` `grid`/`inline-grid`): frame `layout: grid`, `gridColumns` = número de trilhas em `gridTemplateColumns` (valor computado, em px), `columnTracks` = cada trilha em px fixo, `gap` = `columnGap`, `crossGap` = `rowGap`, filhos `fixed`.
  - **Outro contêiner:** frame sem auto layout; filhos com `x = child.x - parent.x`, `y = child.y - parent.y`.
  - Frame sempre com `width/height` do retângulo; `fills` de `backgroundColor` (rgba → `#RRGGBB` + opacidade da pintura), `backgroundImage` `linear-gradient`/`radial-gradient` → pintura `linearGradient`/`radialGradient` com as cores das paradas (ângulo → `from`/`to`), `url(…)` com `image` → filho `image.place` cobrindo o frame (`mode: fill`); bordas uniformes → `strokes: [cor]`, `strokeWeight`, `strokeAlign: inside` (não uniformes → `strokeTopWeight…`; estilo ≠ `solid` → aviso); raios → `cornerRadius` (n ou [tl,tr,br,bl]; `%` → % do menor lado); `boxShadow` → `effects` `dropShadow` (`inset` → `innerShadow`) com x, y, blur, spread, cor; `opacity`; `overflow: hidden|clip` → `clip: true`.
  - **Folha de texto:** `node.create {type: text, text, parent, x, y, width, props: {fontFamily, fontStyle, fontSize, lineHeight: "<n>px" | "auto", letterSpacing, textAlign (left|center|right|justified), textDecoration (underline|strikethrough), textCase (upper|lower|title), fills: [color], textAutoResize: height}}`; cada `run` → `text.style {id: {"$step": n}, start, end, …}` com `textFills`, `fontStyle`, `textDecoration`, e `hyperlink` só se `safeHref` aceitar (senão aviso `link dropped: <texto>`); `href` da folha inteira idem. Folha com fundo não transparente ou borda > 0 (botão, selo) → frame com a caixa (fundo/borda/raio) e o texto dentro no deslocamento do padding.
  - **Fontes:** primeira família de `fontFamily` (sem aspas); família do `FontBook` de mesmo nome sem diferenciar maiúsculas, senão `Inter` + aviso `font <x> replaced by Inter` (uma vez por família). Estilo: peso 100 Thin, 200 ExtraLight, 300 Light, 400 Regular, 500 Medium, 600 SemiBold, 700 Bold, 800 ExtraBold, 900 Black, mais ` Italic` (400 itálico = `Italic`); se a família não tem esse estilo, o estilo disponível de peso mais próximo (empate: o mais pesado), mantendo itálico se houver.
  - **Imagem** (`img` com `image`): `image.place {data, parent, x, y, width, height, mode: cover → fill, contain → fit, fill → crop}` + `node.set {name: alt ou "Imagem"}`; sem `image` → retângulo `#E5E5E5` do tamanho + aviso `image not imported: <src curto>`.
  - **SVG** (`svg` presente): `file.import {data: base64(svg), name: "icon.svg", x, y}` → `node.reparent {ids: [{"$step": n}], parent}` → `node.set {ids, x, y, width, height, name}`; sem `svg` → retângulo + aviso.
  - Mais de `maxLayers` camadas → `steps` vazio e aviso `page too large to import (<n> layers; max 3000)`; `s.truncated` → aviso `page truncated at 3000 elements`; cada `s.blocked` → aviso `blocked network resource: <url>`.
  - Nenhum valor do snapshot vira id de comando ou chave de parâmetro: só os comandos `node.create`, `node.set`, `text.style`, `image.place`, `file.import`, `node.reparent` saem do mapeador.

- [ ] **Step 1: Testes** (com `landing.snapshot.json`):
  - `landingMapsToSteps`: passo 0 é o frame raiz 1440 de largura; há um frame `layout: horizontal` (header), um `layout: grid` com `gridColumns: 3`, um `text` com `fontSize: 48`, um `text.style` com `hyperlink: "https://example.com"`, um `image.place` com `mode: fill` e um `file.import`; todos os `$step` apontam para passos anteriores.
  - `flexAndAlignMapping`: snapshot sintético `justifyContent: space-between`, `alignItems: center`, `flexDirection: column`, `rowGap: 12px` → `layout: vertical`, `mainAlign: spaceBetween`, `crossAlign: center`, `gap: 12`.
  - `fontsFallBackWithWarning`: `fontFamily: "\"Archivo\", sans-serif"` com `FontBook` só de Inter `["Regular","Italic","SemiBold","Bold"]`, peso 800 → `fontFamily: Inter`, `fontStyle: Bold`, aviso `font Archivo replaced by Inter` uma vez para dois textos.
  - `hostileContentStaysData`: `href: "javascript:alert(1)"` → sem `hyperlink`, aviso; texto `"<script>x</script>"` → `text` igual, literal; `cls: "a\"b"` → nome `.a"b` só como valor de `name`; nenhum passo com comando fora da lista.
  - `tooLargeRefused`: 3001 folhas → `steps.isEmpty` e o aviso.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter HTMLImportTests`). **Step 5: Teste com o motor real** `realEngineAcceptsLandingSteps` (`.enabled(if: realBuilt)`, dentro da suíte `.serialized`): roda os passos do landing por `figcraft-cli run` (o mesmo formato `{command, params}` com `$step`), todos `ok`; `inspect.document` tem ≥ 20 camadas sob a raiz. Ajustar o mapeador onde o motor recusar (nomes de propriedades, formato de `effects`/gradiente) e registrar no relatório. **Step 6:** Commit `feat(import): map DOM snapshots to figcraft commands`.

### Task 3: Origem com pasta + estados de importação no registro

**Files:** Modify `Sources/OrqDaemonKit/Artifacts/ArtifactStore.swift`, `Sources/OrqDaemonKit/ArtifactCommands.swift`, `Sources/OrqProtocol/Plugins.swift`; Test `Tests/OrqDaemonKitTests/ArtifactTests.swift`

**Interfaces:**
- Produces: `Artifact` ganha `var source: String? = nil` (caminho relativo a `<root>/artifacts` da página de origem) e `var importError: String? = nil` (registros antigos decodificam; agente antigo sem `source` = `<id>/source.html`).
- Produces: `artifact.add --path <arquivo> [--root <pasta>] [--title]`: sem `--root`, como no 2C (`<id>/source.html`). Com `--root`: a página tem de estar dentro de `root` (depois de `standardizedFileURL`); copia a árvore de `root` para `<id>/source/` — só arquivos regulares (`lstat`, sem symlink; diretório symlink pulado), extensões `html htm css js mjs json png jpg jpeg gif webp avif svg ico woff woff2 ttf otf` (sem diferenciar maiúsculas), ≤ 2000 arquivos e ≤ 64 MiB no total (passar disso → `.invalidArgs`, nada copiado), nomes começando com `.` pulados; `source` = `<id>/source/<caminho relativo da página>`; arquivos 0444, pastas 0555 ao fim. Leitura e cópia fora do pool.
- Produces: `func convertToExport(_ id: UUID, fileId: String, node: String, page: String?) async throws -> (Artifact, URL)` no `ArtifactStore`: reserva `v1` sob o mesmo id (o artifact vira `kind: export`, `source` mantido); `ArtifactStore.setImportError(_ id: UUID, _ message: String?) async throws`.
- `artifact.list`/`get`: campo novo `source` (`orq-artifact://app/<source>` ou null) e `importError`; status novo `importing` (id no conjunto em memória do router) e `failed` (`agent` com `importError`). Ordem de precedência: `importing` > `failed` > `pending`.

- [ ] **Step 1: Testes:** `addWithRootCopiesTree` (pasta com `index.html`, `css/style.css`, `img/a.png`, `.git/x`, symlink → `source/` tem os 3 arquivos, sem `.git` nem symlink, 0444; `source` = `<id>/source/index.html`); `addRootRefusesOutsideAndHuge` (página fora de `root` → `.invalidArgs`; 2001 arquivos → `.invalidArgs` sem pasta criada); `oldAgentRecordsDecode`; `statusPrecedence` (failed/importing/pending).
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter ArtifactTests`). **Step 5:** Commit `feat(artifacts): archive source folders and import states`.

### Task 4: Orquestração da importação

**Files:** Create `Sources/OrqDaemonKit/ArtifactImport.swift`, `Tests/OrqDaemonKitTests/ArtifactImportTests.swift`; Modify `Sources/OrqDaemonKit/ArtifactCommands.swift`, `Sources/OrqDaemonKit/Design/DesignService.swift`, `Sources/OrqProtocol/Plugins.swift`, `Tests/Fixtures/fake-figcraft-mcp.py`

**Interfaces:**
- Consumes: `PluginHost.callApp` (Task 1), `HTMLImport.steps`/`DOMSnapshot`/`FontBook` (Task 2), `convertToExport`/`setImportError` (Task 3), `design.create(_:floor:deadline:)`, `enableActiveSystem`, `onSystemClient`, `systemSnapshot`, `exportHTML` (2C).
- Produces: `func importArtifact(_ id: UUID, width: Int, by: String) async throws -> JSONValue` no router:
  1. artifact `agent` (senão `.invalidArgs` "already imported: edit its design screen"); marca `importing`.
  2. `host.callApp(command: "html.snapshot", args: {url: orq-artifact://app/<source>, width}, timeout: 40 s)` → `DOMSnapshot` (JSON inválido → `.internal` "bad snapshot").
  3. Arquivo novo: nome = título limpo para as regras do 2A (`DesignService.validate`; caracteres fora → `-`; máx. 80) e único (`… 2`, `… 3`), no andar do artifact; `enableActiveSystem`.
  4. `FontBook`: `text.fonts {}` e, por família usada no snapshot, `text.fonts {family}` no cliente do daemon desse arquivo.
  5. `HTMLImport.steps(…, name: título)`; vazio → falha com o aviso como mensagem.
  6. `batch {commands: steps, label: "Importar <título>"}` no cliente do daemon (um passo de desfazer); raiz = id do resultado do passo 0.
  7. `systemSnapshot(fileId, node: raiz)` + `exportHTML` **no mesmo artifact** (via `convertToExport`); avisos do import + do export juntos no artifact.
  8. Sucesso → `{artifact, file, node, version: 1, warnings}`; falha em qualquer passo → `setImportError(id, mensagem scrubbed)`, `importing` sai, erro devolvido; arquivo de design já criado fica (aviso no erro: `design file <nome> kept`).
  Um prazo para tudo: `design.deadline("artifact.import")` = 180 s.
- `artifact.add` (Task 3) depois de registrar dispara `importArtifact` em segundo plano (`Task`), resposta `{id, importing: true}`; `artifact.import <id> [--width]` (terminal ou app, `timeout` 180) roda e espera. Evento `artifact.imported` (`{id, file}`) para os painéis `artifacts`.
- Fake: `text.fonts` → `["Inter"]` / `{family: Inter}` → `["Regular","Italic","SemiBold","Bold"]`; `batch` devolve ids sequenciais por passo; `file.import`, `image.place`, `node.reparent` aceitos; host falso do app (padrão de `PluginHostTests`) responde `html.snapshot` com `landing.snapshot.json`.

- [ ] **Step 1: Testes** (serializados com `DesignCommandTests`):
  - `agentHTMLBecomesScreen`: terminal `artifact.add --path landing/index.html --root landing` → `{importing: true}`; depois de esperar (`artifact.list` até `current`, ≤ 10 s) o artifact é `kind export`, `file` = nome do título, `source` continua servindo o HTML original, `v1/index.html` existe; o log do fake mostra um único `batch` com label `Importar …`.
  - `importWithoutAppFails`: sem host → status `failed`, `importError` contém "Orq app is not running"; com host conectado, `artifact.import <id>` → sucesso.
  - `reimportOfExportRefused`: `artifact.import` num export → `.invalidArgs`.
  - `uniqueFileNames`: dois imports com o mesmo título → arquivos `T` e `T 2`.
  - `importStaysOnAgentFloor`: artifact de terminal num andar → arquivo com `floorId` do andar.
- [ ] **Step 2–4:** FAIL → implementar → PASS (`swift test --filter "ArtifactImportTests|ArtifactTests"`). **Step 5:** Commit `feat(import): agent html becomes a design screen`.

### Task 5: Painel, ida e volta com o motor real e docs

**Files:** Modify `Sources/OrqPlugins/ArtifactsPanel.swift`, `Tests/OrqPluginsTests/ArtifactsPanelTests.swift`, `Tests/OrqDaemonKitTests/DesignCommandTests.swift`, `README.md`, `docs/superpowers/plans/2026-10-20-phase2-roadmap.md`; Create (scratchpad, fora do repo) `plan2d-checklist-visual.md`

**Interfaces:** Consumes Tasks 1–4.
- Painel: rótulos novos `importing` → "importando…", `failed` → "falha na importação" (com `importError` no `help`); ação **Abrir origem** (quando `source` existe: abre `source` no Navegador como o 2C abre `url`); ação **Importar de novo** (só `failed`): `artifact.import {id}` e depois `refresh`.
- [ ] **Step 1: Testes:** `rowsShowImportStates` e `modelReimportsThenRefreshes` (call falso); `realEngineImportsLanding` (`realBuilt`, motor real, host falso respondendo com `landing.snapshot.json`): `artifact.add --root` → `current`; `design.inspect --node <raiz>` tem ≥ 20 camadas; o `index.html` exportado contém `display: grid` e o texto do h1.
- [ ] **Step 2: Caso de teste real do usuário (fora do repo).** O usuário indicou um canvas real dele (desktop 1440×810 e a versão mobile 390×844). As páginas achatadas (templates expandidos no estado padrão, sem o runtime do canvas) ficam em `<scratchpad>/import-case/flat/{replay.html,mobile.html}` (o controlador passa o caminho). Rodar o pipeline real com elas — `HTMLSnapshotter` (WebKit real) → `HTMLImport.steps` → `figcraft-cli run` → `figcraft-cli render` — por um teste `.disabled` ou script que lê o caminho de uma variável de ambiente (`ORQ_IMPORT_CASE`); gravar os PNG e um relatório curto de fidelidade no mesmo scratchpad. **Nada desse caso entra no repo** (é design de produto do usuário).
- [ ] **Step 3:** Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test` → verde.
- [ ] **Step 4:** README: seção "Importar HTML" (fluxo, `--root`, rede bloqueada, limites, aproximação aceitável, app precisa estar aberto). Roteiro: 2D "em execução". Checklist humana no scratchpad: importar o fixture `landing/` por um terminal; abrir a tela no painel Design; comparar com a origem (Abrir origem); importar o caso real do usuário (`flat/replay.html` e `flat/mobile.html`, com `--root` na pasta) e anotar o que ficou diferente; app fechado → `failed` → abrir o app → Importar de novo.
- [ ] **Step 5:** Commit `feat(artifacts): import states in the panel; real engine round trip; docs`.

---

## Fora deste plano (anotar no README)

- Ligar cores/tipos importados às variáveis do design system ativo (o arquivo novo só ganha a biblioteca habilitada).
- Pseudo-elementos (`::before/::after`), `transform`, animações, `position: sticky`, formulários interativos, iframes e vídeo não entram (ou entram como caixa).
- Fontes da web não carregam (rede bloqueada): a página é lida com as fontes locais.
- Importar para um arquivo de design existente (sempre arquivo novo).
