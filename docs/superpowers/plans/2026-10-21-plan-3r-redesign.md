# Plano 3R — Redesign visual (temas e estruturas) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O app ganha identidade própria: dois temas (**Escuro** índigo/menta, **Claro** papel/cobalto, mais **Sistema**), duas estruturas de janela (**Compacta**: canvas inteiro com cabeçalho flutuante; **Completa**: barra lateral de workspace, cabeçalho do andar e barra de status), tipografia Space Grotesk + DM Mono e uma janela de Preferências para escolher tudo isso.

**Architecture:** Um alvo novo `OrqTheme` (AppKit + SwiftUI, sem dependências) guarda as cores como `NSColor` **dinâmicas** (mudam com a aparência), as fontes com fallback, as escolhas salvas em `UserDefaults` e os componentes SwiftUI comuns (botões, cartões, etiquetas, cabeçalho de painel). Trocar o tema é só `NSApp.appearance = …`: tudo que usa os tokens acompanha, inclusive o AppKit do canvas (camadas recoloridas em `viewDidChangeEffectiveAppearance`). A estrutura é só a moldura em volta do mesmo `DockShell` + `CanvasView`: nada no daemon, no protocolo ou no `layout.json` muda.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, SwiftUI + AppKit; fontes Space Grotesk e DM Mono (SIL OFL 1.1, baixadas por script como o scrcpy-server); nenhuma dependência de código nova.

**Spec:** não há spec escrita; a fonte é o artifact de redesign (Design, privado do usuário) `https://claude.ai/artifact/VR9jCWhkCS4gppQL4RxeUy` — linhas 2 (Compacta/Completa × Escuro/Claro), 3 (partituras, Novo terminal, Memória, Artifacts) e 4 (Design, Dispositivo, Preferências, Salvar partitura) — e as decisões do usuário de 2026-10-21: temas B e C da exploração viram Escuro e Claro; estrutura C = Compacta, B = Completa, as duas disponíveis; **cada nó continua sendo o terminal real conversável** (o chat de trabalho só soma). Roteiro: `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`. Base: `main` com 2E e 2F.

## Global Constraints

- **Só UI.** Nenhum comando, evento, campo de protocolo, arquivo do daemon ou formato do `layout.json` muda. Trocar tema ou estrutura não move nó, não fecha painel e não reinicia terminal.
- **O nó é o terminal.** O corpo do nó segue sendo o PTY real (`ui.attach`); o redesign só muda moldura, cores e fonte.
- **Clean-room:** nada de cor, ícone, texto ou layout copiado do Maestri; só os tokens abaixo.
- **Contraste AA:** todo token de texto (`text`, `textSecondary`, `muted`, `accent`, `attention`, `secondary`, `danger`) tem razão ≥ 4.5 contra `background`, `surface`, `sidebar` e `sunken` nos dois temas; `onAccent` ≥ 4.5 contra `accent`.
- **Acessibilidade básica:** botão só com ícone tem `.help` e `accessibilityLabel`; foco de teclado visível (anel do sistema, não removido); estado nunca só por cor (badge tem texto ou forma junto).
- Textos de UI em **português**; nomes de código em inglês. UI na main thread só para desenhar; nada de I/O bloqueante novo.
- Fontes ausentes (rodando por `swift run`, ou script não rodado) → fontes do sistema, sem erro.
- Valores de preferência desconhecidos (gravados por outra versão) → padrão: tema **Escuro**, estrutura **Compacta**, fonte do terminal **DM Mono 13**.

**Tokens** (hex exatos; `Palette.dark` / `Palette.light`):

| token | Escuro | Claro | uso |
|---|---|---|---|
| `background` | `#0E1326` | `#F3F4F1` | canvas, janela |
| `surface` | `#161C36` | `#FFFFFF` | nós, cartões, folhas |
| `sidebar` | `#121831` | `#ECEDE9` | barra lateral, docas, barra de título do nó |
| `sunken` | `#0B1020` | `#F7F7F5` | corpo do terminal, campos |
| `raised` | `#1B2340` | `#E3E7F7` | item selecionado |
| `border` | `#262E52` | `#D9DBD5` | bordas |
| `borderSoft` | `#1E2647` | `#E4E5E0` | divisórias internas |
| `grid` | `#151B33` | `#E4E5E0` | pontos do canvas |
| `scrim` | `#070A16` | `#C9CBC5` | fundo atrás de folha (uso nos mockups; a folha nativa já escurece) |
| `text` | `#E8ECF8` | `#15171C` | texto |
| `textSecondary` | `#B6BEDB` | `#2E323B` | texto de apoio |
| `muted` | `#8C95B8` | `#5C6270` | rótulos, mono de apoio |
| `accent` | `#6EE7B7` | `#2448C9` | ação principal, corda entre agentes, Maestro |
| `onAccent` | `#0E1326` | `#FFFFFF` | texto sobre `accent` |
| `attention` | `#FFB86B` | `#A14A06` | "espera você", pedidos de permissão |
| `attentionTint` | `#2A2418` | `#FDF6EE` | fundo de aviso |
| `secondary` | `#93A4FF` | `#6B3FC4` | corda de painel, "trabalhando", links |
| `danger` | `#FF8A8A` | `#B42318` | encerrado, erro, desconectado |

(Claro `attention` é `#A14A06`, não o `#B45309` do mockup: `#B45309` dá 4.27 sobre `sidebar`.)

**Tipografia:** UI em Space Grotesk (títulos 18–22 semibold, corpo 13–14 regular/medium); rótulos técnicos, caminhos, presets e números em DM Mono 11–13. Terminal: DM Mono 13 por padrão.

## Review Focus

1. **Trocar o tema com terminais abertos** → fundo, borda e barra de título dos nós, cordas, minimapa e cores do terminal (fundo, texto, cursor, seleção) mudam na hora, sem reiniciar nada. Teste: Task 1 `dynamicColorsFollowAppearance`; Task 4 passo de verificação manual "trocar tema com 3 terminais".
2. **Fontes não instaladas** (`swift run OrqApp`, ou `fetch-fonts.sh` não rodado) → tudo em fonte do sistema, terminal em `monospacedSystemFont`, nada quebra. Teste: Task 2 `missingFamilyFallsBackToSystem`.
3. **Preferência gravada por outra versão** (`appearance.theme = "sepia"`, `appearance.structure = 7`, tamanho 40) → Escuro, Compacta, tamanho preso a 11…16. Teste: Task 3 `unknownValuesUseDefaults`.
4. **Trocar a estrutura com painéis em doca e no canvas** → os mesmos painéis continuam vivos (mesma instância do `PanelViewStore`, webview não recarrega), nós não mudam de lugar. Teste: Task 5 verificação manual "trocar estrutura com Navegador aberto numa página logada".
5. **Muitos andares** (15) → na Compacta, chips mostram o atual + até 3 e o resto em "+N"; na Completa a lista rola. Teste: Task 5 `chipsOverflow` (função pura em `OrqTheme`).

---

## File Structure

```
Package.swift                                   + target OrqTheme, + testTarget OrqThemeTests; OrqApp e OrqPlugins dependem de OrqTheme
Sources/OrqTheme/Palette.swift                  Palette (valores), OrqColor (NSColor dinâmicas), contraste
Sources/OrqTheme/Typography.swift               OrqFont (UI/mono com fallback), Font.orq*
Sources/OrqTheme/Appearance.swift               ThemeChoice, WindowStructure, TerminalFontChoice, AppearanceKeys, chips
Sources/OrqTheme/Components.swift               OrqButtonStyle, OrqCard, OrqTag, PanelHeader, PanelFooter, ChoiceCard
Sources/OrqApp/PreferencesView.swift            janela Preferências (Aparência)
Sources/OrqApp/Shell.swift                      CompactShell, FullShell, WorkspaceSidebar, FloorHeader, StatusBar
Sources/OrqApp/CommandPalette.swift             ⌘K
Sources/OrqApp/{OrqApp,FloorBar,DockView,CanvasViewport,CordLayer,TerminalNodeView,PanelNodeView,TerminalSheet,OpenPanelSheet,UsagePopover}.swift
Sources/OrqPlugins/{MemoryPanel,ArtifactsPanel,DesignPanel,DevicePanel,DesignSystemsPanel,BrowserPanel}.swift   só a moldura
scripts/fetch-fonts.sh, scripts/bundle-app.sh, Resources/Info.plist, Resources/NOTICE-fonts
Tests/OrqThemeTests/{PaletteTests,TypographyTests,AppearanceTests}.swift
README.md, docs/superpowers/plans/2026-10-24-phase3-roadmap.md
```

---

### Task 1: Tokens de cor

**Files:** Modify `Package.swift`; Create `Sources/OrqTheme/Palette.swift`, `Tests/OrqThemeTests/PaletteTests.swift`

**Interfaces:**
- Produces:
  - `public struct Palette: Sendable, Equatable` com um `public let` por token da tabela (tipo `RGB`, `public struct RGB: Sendable, Equatable { r, g, b: UInt8; init(hex: UInt32) }`), `public static let dark`, `public static let light`.
  - `public enum OrqColor` com um `public static let <token>: NSColor` por token, criado com `NSColor(name: "orq.<token>") { appearance in … }` escolhendo `Palette.dark` quando `appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua`, senão `.light`.
  - `extension ShapeStyle where Self == Color { public static var orq<Token>: Color }` — um por token (`.orqAccent`, `.orqMuted`…), cada um `Color(nsColor: OrqColor.<token>)`; SwiftUI herda a dinâmica do `NSColor`.
  - `public func contrastRatio(_ a: RGB, _ b: RGB) -> Double` (WCAG 2.x, luminância relativa sRGB).

- [ ] **Step 1: Alvos.** Em `Package.swift`: `.target(name: "OrqTheme")`, `.testTarget(name: "OrqThemeTests", dependencies: ["OrqTheme"])`; `OrqApp` e `OrqPlugins` ganham `"OrqTheme"` nas dependências.

- [ ] **Step 2: Testes que falham** (`PaletteTests.swift`):

```swift
@Test func tokensMatchSpec() {
    #expect(Palette.dark.background == RGB(hex: 0x0E1326))
    #expect(Palette.dark.accent == RGB(hex: 0x6EE7B7))
    #expect(Palette.light.accent == RGB(hex: 0x2448C9))
    #expect(Palette.light.attention == RGB(hex: 0xA14A06))
}
@Test(arguments: [Palette.dark, Palette.light]) func textTokensPassAA(_ p: Palette) {
    for fg in [p.text, p.textSecondary, p.muted, p.accent, p.attention, p.secondary, p.danger] {
        for bg in [p.background, p.surface, p.sidebar, p.sunken] { #expect(contrastRatio(fg, bg) >= 4.5) }
    }
    #expect(contrastRatio(p.onAccent, p.accent) >= 4.5)
}
@Test func dynamicColorsFollowAppearance() {
    func rgb(_ name: NSAppearance.Name) -> NSColor {
        var c = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { c = OrqColor.background.usingColorSpace(.sRGB)! }
        return c
    }
    #expect(abs(rgb(.darkAqua).redComponent - 0x0E / 255) < 0.01)
    #expect(abs(rgb(.aqua).redComponent - 0xF3 / 255) < 0.01)
}
@Test func contrastKnownPair() { #expect(abs(contrastRatio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)) - 21) < 0.01) }
```

- [ ] **Step 3:** `swift test --filter OrqThemeTests` → FAIL (alvo sem código).
- [ ] **Step 4: Implementar** `Palette.swift` com os valores da tabela das Global Constraints.
- [ ] **Step 5:** `swift test --filter OrqThemeTests` → PASS.
- [ ] **Step 6: Commit** `feat(theme): add OrqTheme palette with dynamic colors`

---

### Task 2: Fontes

**Files:** Create `scripts/fetch-fonts.sh`, `Resources/NOTICE-fonts`, `Sources/OrqTheme/Typography.swift`, `Tests/OrqThemeTests/TypographyTests.swift`; Modify `scripts/bundle-app.sh`, `Resources/Info.plist`

**Interfaces:**
- Produces:
  - `public enum OrqFont { public static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular, family: String = uiFamily) -> NSFont; public static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular, family: String = monoFamily) -> NSFont; public static let uiFamily = "Space Grotesk", monoFamily = "DM Mono" }` — família ausente (`NSFontManager.shared.availableMembers(ofFontFamily:) == nil`) → `.systemFont(ofSize:weight:)` / `.monospacedSystemFont(ofSize:weight:)`. O peso vai pelo descritor (`.traits: [.weight: …]`), o que funciona com a Space Grotesk variável.
  - `extension Font { public static func orqUI(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font; public static func orqMono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font }` — `Font(OrqFont.ui(…))`.

- [ ] **Step 1: Teste que falha:**

```swift
@Test func missingFamilyFallsBackToSystem() {
    let f = OrqFont.ui(14, .semibold, family: "Família Que Não Existe")
    #expect(f.familyName == NSFont.systemFont(ofSize: 14).familyName)
    let m = OrqFont.mono(13, family: "Família Que Não Existe")
    #expect(m.isFixedPitch)
}
@Test func sizeIsKept() { #expect(OrqFont.mono(13).pointSize == 13) }
```

- [ ] **Step 2:** `swift test --filter TypographyTests` → FAIL.
- [ ] **Step 3: Implementar `Typography.swift`.**
- [ ] **Step 4:** `swift test --filter TypographyTests` → PASS.
- [ ] **Step 5: Script** `scripts/fetch-fonts.sh`, no molde de `fetch-scrcpy-server.sh`: baixa de `https://raw.githubusercontent.com/google/fonts/<COMMIT>/ofl/` os arquivos `spacegrotesk/SpaceGrotesk[wght].ttf`, `spacegrotesk/OFL.txt`, `dmmono/DMMono-Regular.ttf`, `dmmono/DMMono-Medium.ttf` para `vendor/fonts/` (já ignorado por `vendor/`), cada um conferido contra SHA-256 fixo no script. O executor escolhe o commit do `google/fonts` no dia, grava o hash do commit e os quatro SHA-256 no script.
- [ ] **Step 6: Bundle.** `Resources/Info.plist` ganha `<key>ATSApplicationFontsPath</key><string>Fonts</string>` (o macOS registra sozinho as fontes de `Contents/Resources/Fonts`, sem código). `bundle-app.sh`: se `vendor/fonts` existe, `cp vendor/fonts/*.ttf` para `$APP/Contents/Resources/Fonts/` e `cp Resources/NOTICE-fonts` para `Resources/`; senão `warning: vendor/fonts missing (run scripts/fetch-fonts.sh): system fonts` e segue. `NOTICE-fonts`: nomes, autores (Florian Karsten; Colophon Foundry), licença SIL OFL 1.1 e o texto do `OFL.txt`.
- [ ] **Step 7: Verificar:** `scripts/fetch-fonts.sh && scripts/bundle-app.sh`, abrir `build/Orq.app`; no app, um `print(NSFontManager.shared.availableMembers(ofFontFamily: "Space Grotesk") != nil)` temporário (removido antes do commit) imprime `true`.
- [ ] **Step 8: Commit** `feat(theme): bundle Space Grotesk and DM Mono with system fallback`

---

### Task 3: Preferências — tema, estrutura, fonte do terminal

**Files:** Create `Sources/OrqTheme/Appearance.swift`, `Sources/OrqTheme/Components.swift`, `Sources/OrqApp/PreferencesView.swift`, `Tests/OrqThemeTests/AppearanceTests.swift`; Modify `Sources/OrqApp/OrqApp.swift`

**Interfaces:**
- Produces (`OrqTheme`):
  - `public enum ThemeChoice: String, CaseIterable, Sendable { case dark, light, system; public var appearance: NSAppearance? }` — `dark` → `.darkAqua`, `light` → `.aqua`, `system` → `nil`.
  - `public enum WindowStructure: String, CaseIterable, Sendable { case compact, full }`.
  - `public struct TerminalFontChoice: Sendable, Equatable { public var family: String; public var size: CGFloat; public static let `default` = TerminalFontChoice(family: "DM Mono", size: 13); public static let families = ["DM Mono", "SF Mono", "Menlo"]; public static let sizes: ClosedRange<CGFloat> = 11...16; public var font: NSFont }` — `"SF Mono"` → `monospacedSystemFont`; outras via `OrqFont.mono(size, family:)`.
  - `public enum AppearanceKeys { public static let theme = "appearance.theme", structure = "appearance.structure", terminalFamily = "appearance.terminalFamily", terminalSize = "appearance.terminalSize" }` e `public struct AppearanceSettings: Equatable { theme, structure, terminalFont; public init(defaults: UserDefaults) }` — leitura tolerante: raw value desconhecido → padrão; família fora de `families` → `DM Mono`; tamanho 0/ausente → 13, fora da faixa → preso a 11…16.
  - Componentes (`Components.swift`), todos lendo `OrqColor`/`Font.orq*`:
    - `public struct OrqButtonStyle: ButtonStyle { public enum Kind { case primary, secondary, quiet, attention }; public init(_ kind: Kind = .secondary) }` — altura 32 (40 com `.controlSize(.large)`), raio 9–10; `primary` = `accent`/`onAccent`; `secondary` = borda `border`, fundo transparente; `quiet` = texto `muted`, sem borda; `attention` = `attention`/`background`.
    - `public struct OrqCard: ViewModifier` (`surface`, borda `border` 1 pt, raio 14) + `extension View { public func orqCard(highlight: Color? = nil) -> some View }` (borda passa a `highlight`).
    - `public struct OrqTag: View { init(_ text: String, tone: Tone) }`, `Tone { neutral, accent, attention, secondary }` — DM Mono 11 medium, raio 6.
    - `public struct PanelHeader: View { init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> some View) }` — título Space Grotesk 18 semibold, subtítulo DM Mono 12 `muted`, divisória `border` embaixo, padding 20/14.
    - `public struct PanelFooter: View { init(_ leading: String, trailing: String? = nil) }` — DM Mono 12 `muted`, divisória em cima.
    - `public struct ChoiceCard<Preview: View>: View { init(_ title: String, subtitle: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) }` — borda `accent` + fundo `raised` quando selecionado; `accessibilityAddTraits(.isSelected)` quando selecionado.
- Consumes: `Palette`, `OrqColor`, `OrqFont` (Tasks 1–2).

- [ ] **Step 1: Testes que falham:**

```swift
@Test func themeAppearance() {
    #expect(ThemeChoice.dark.appearance?.name == .darkAqua)
    #expect(ThemeChoice.light.appearance?.name == .aqua)
    #expect(ThemeChoice.system.appearance == nil)
}
@Test func unknownValuesUseDefaults() {
    let d = UserDefaults(suiteName: "orq.test.\(UUID())")!
    d.set("sepia", forKey: AppearanceKeys.theme); d.set(7, forKey: AppearanceKeys.structure)
    d.set("Comic Sans", forKey: AppearanceKeys.terminalFamily); d.set(40.0, forKey: AppearanceKeys.terminalSize)
    let s = AppearanceSettings(defaults: d)
    #expect(s.theme == .dark && s.structure == .compact)
    #expect(s.terminalFont == TerminalFontChoice(family: "DM Mono", size: 16))
}
@Test func emptyDefaults() {
    let s = AppearanceSettings(defaults: UserDefaults(suiteName: "orq.test.\(UUID())")!)
    #expect(s == AppearanceSettings(theme: .dark, structure: .compact, terminalFont: .default))
}
```

- [ ] **Step 2:** `swift test --filter AppearanceTests` → FAIL.
- [ ] **Step 3: Implementar `Appearance.swift` e `Components.swift`.**
- [ ] **Step 4:** `swift test --filter AppearanceTests` → PASS.
- [ ] **Step 5: Janela Preferências** (`PreferencesView.swift`), aberta por ⌘, via cena `Settings { PreferencesView() }` em `OrqApp`. Uma página só, **Aparência** (sem barra de seções até haver uma segunda), igual à tela "Preferências · Escuro" do artifact:
  - **Tema:** 3 `ChoiceCard` (Escuro "fundo índigo, menta", Claro "papel, cobalto", Sistema "segue o macOS") com miniatura feita de retângulos nas cores do tema.
  - **Estrutura:** 2 `ChoiceCard` (Compacta "canvas + cabeçalho flutuante", Completa "barra lateral, andares e status") com miniatura, e a linha "Muda só a moldura. Terminais, cordas e painéis ficam onde estão."
  - **Terminal:** `Picker` de família (`TerminalFontChoice.families`) e de tamanho (11…16 pt).
  - Tudo em `@AppStorage` com as chaves de `AppearanceKeys`.
  - Fica de fora a opção "Reduzir movimento das cordas" que aparece no mockup: as cordas hoje não se mexem.
- [ ] **Step 6: Aplicar o tema.** Em `OrqApp`: `@AppStorage(AppearanceKeys.theme)`, e na abertura e em `.onChange` → `NSApp.appearance = AppearanceSettings(defaults: .standard).theme.appearance`. A janela principal e a de Preferências mudam juntas.
- [ ] **Step 7: Verificar:** `swift build --product OrqApp`; abrir, ⌘, → trocar Escuro/Claro/Sistema muda a janela de Preferências na hora; Sistema segue a troca do macOS em Ajustes → Aparência.
- [ ] **Step 8: Commit** `feat(app): preferences window with theme, structure and terminal font`

---

### Task 4: Canvas, nós, cordas e terminal no novo estilo

**Files:** Modify `Sources/OrqApp/CanvasViewport.swift`, `CordLayer.swift`, `TerminalNodeView.swift`, `PanelNodeView.swift`

**Interfaces:**
- Consumes: `OrqColor`, `OrqFont`, `Font.orq*`, `OrqTag`, `AppearanceSettings`, `TerminalFontChoice.font` (Tasks 1–3); `client.badges`, `client.connections`, `TerminalRecord.isMaestro`, `TerminalRecord.preset` (existentes).
- Produces: nada que outra task use; só a regra **"camada com `cgColor` é recolorida em `viewDidChangeEffectiveAppearance` dentro de `effectiveAppearance.performAsCurrentDrawingAppearance { … }`"**, que a Task 6 repete no que for AppKit.

- [ ] **Step 1: Canvas.** Fundo `OrqColor.background`; grade de pontos `OrqColor.grid` de 1 pt a cada 24 pt de canvas, desenhada em `draw(_:)` só na área visível, omitida com zoom < 0.5. Minimapa: fundo `sidebar` 90%, quadros `muted`, retângulo visível `accent`.
- [ ] **Step 2: Nó de terminal.** Raio 14, borda 1 pt `border`, fundo `surface`. Barra de título (`titleHeight` 24 → 32, fundo `sidebar`): bolinha de estado + nome em Space Grotesk 13 semibold + preset em DM Mono 11 `muted`. No Maestro, a coroa amarela sai e entra `OrqTag("Maestro", tone: .accent)`, além de "regendo N" em DM Mono, onde N é o número de cordas do nó. Estados, sempre com cor **e** texto:
  - ocioso: bolinha `muted`, sem texto;
  - trabalhando: bolinha `secondary` + "trabalhando";
  - atenção: bolinha `attention` + "espera você" e borda do nó 1.5 pt `attention`;
  - parado: bolinha `danger` + o "encerrado (código N)" que já existe.
- [ ] **Step 3: Terminal.**
  - Corpo: `nativeBackgroundColor = sunken`, `nativeForegroundColor = text`, `caretColor = accent` e seleção em `accent` a 30%. A paleta ANSI não muda.
  - Fonte: `AppearanceSettings(defaults: .standard).terminalFont.font` no lugar de `.monospacedSystemFont(ofSize: 12)`.
  - Troca de fonte nas Preferências: `UserDefaults.didChangeNotification` → reaplica a fonte, sem reiniciar o processo. Colunas e linhas mudam e o redimensionamento atual do PTY cuida disso.
  - SwiftTerm guarda cores fixas, então em `viewDidChangeEffectiveAppearance` as quatro cores são reatribuídas.
- [ ] **Step 4: Cordas.** Agente↔agente: 2 pt `accent`, ponta redonda. Agente↔painel: 2 pt `secondary`, tracejado `[2, 6]`. Selecionada: 3 pt. Arrastando uma corda nova: `accent`, tracejado `[4, 4]`, como hoje.
- [ ] **Step 5: Nó de painel.** Mesma moldura do terminal. Título: nome do painel + DM Mono do alvo (`url`, arquivo ou aparelho, quando houver).
- [ ] **Step 6: Verificar à mão** (`swift run OrqApp` com `ORQ_ROOT` de teste):
  - 3 terminais (um Maestro), 2 cordas e um Navegador no canvas.
  - Trocar o tema nas Preferências: fundo, grade, nós, títulos, cordas, minimapa e terminal mudam sem reiniciar. O texto que já estava no terminal continua lá.
  - Trocar para "SF Mono 15": o terminal reflui e o shell recebe o novo tamanho (`tput cols` muda).
- [ ] **Step 7: Commit** `feat(app): restyle canvas, nodes, cords and terminals`

---

### Task 5: Estruturas Compacta e Completa + ⌘K

**Files:** Create `Sources/OrqApp/Shell.swift`, `Sources/OrqApp/CommandPalette.swift`; Modify `Sources/OrqApp/OrqApp.swift` (`ContentView`), `FloorBar.swift`, `DockView.swift`, `UsagePopover.swift`, `Sources/OrqTheme/Appearance.swift`, `Tests/OrqThemeTests/AppearanceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; `DockShell`, `CanvasView`, `FloorBar`, `UsagePopover`, `PanelMeter`, `hostNotice`, `connection` (existentes).
- Produces:
  - `OrqTheme`: `public func chipSplit<T: Equatable>(_ items: [T], current: T?, max: Int) -> (shown: [T], overflow: [T])` — `shown` mantém a ordem e sempre inclui `current`. Com `max` 4: o atual mais até 3 outros.
  - `FloorMenu: View` (em `FloorBar.swift`): o menu do andar que hoje está dentro de `FloorBar` (Status, Land, Excluir…), com seus `sheet`, `alert` e `confirmationDialog` e o estado `busy`, extraído sem mudar o comportamento. `FloorBar` passa a usá-lo, e o atalho "Novo andar…" vira `NewFloorButton` no mesmo arquivo.
  - `CommandPalette: View` com `struct PaletteCommand: Identifiable { id: String; title: String; run: () -> Void }`. Filtra por `title.localizedStandardContains(query)`, ↑/↓ escolhem e ↩ executa.

- [ ] **Step 1: Teste que falha:**

```swift
@Test func chipsOverflow() {
    let all = Array(0..<15)
    let (shown, over) = chipSplit(all, current: 12, max: 4)
    #expect(shown == [0, 1, 2, 12] && over.count == 11 && !over.contains(12))
    #expect(chipSplit([0, 1], current: nil, max: 4) == ([0, 1], []))
}
```

- [ ] **Step 2:** `swift test --filter chipsOverflow` → FAIL; implementar `chipSplit`; → PASS.
- [ ] **Step 3: Moldura comum.**
  - `ContentView` lê `@AppStorage(AppearanceKeys.structure)` e mostra `CompactShell` ou `FullShell`. As duas embrulham o **mesmo** `DockShell { CanvasView … }`, criado uma vez em `ContentView` e passado como conteúdo, para que trocar de estrutura não recrie `CanvasView` nem os painéis.
  - A barra de ferramentas da janela some nas duas (`.toolbar(.hidden, for: .windowToolbar)`); os semáforos da janela ficam. Os itens da barra atual são distribuídos como nos passos 4 e 5.
  - Docas:
    - abas em Space Grotesk 13;
    - aba selecionada com fundo `raised`;
    - fundo `sidebar`;
    - na Compacta, cada doca fica dentro de um cartão (`orqCard`, inset 12, raio 18).
- [ ] **Step 4: `CompactShell`** (artifact "Compacta · Escuro/Claro"): canvas até a borda, com uma barra flutuante no topo à esquerda (fundo `surface` 92%, borda `border`, raio 14, altura 44). Contém, nesta ordem:
  - a palavra "orq" em Space Grotesk 15 bold;
  - chips de andar: Térreo + `chipSplit(floors, current:, max: 4)`, com bolinha de status, o atual em `raised`; um chip "+N" abre menu com o resto e "Novo andar…"; o clique direito num chip abre `FloorMenu`;
  - o campo "Comando" com o texto fantasma "Recrutar, abrir painel, aplicar partitura…" e o atalho ⌘K, que abre a `CommandPalette`;
  - o botão de uso com o resumo "41% · 12%" (a maior porcentagem de cada provedor do `UsagePopover`, que abre no clique).

  No topo à direita ficam, flutuando, o zoom em DM Mono e o "Ajustar à tela". Abaixo da barra, o banner de erro, o de serviço desatualizado e o `hostNotice`. O estado da conexão aparece só quando está desconectado: chip `danger` "Desconectado: motivo".
- [ ] **Step 5: `FullShell`** (artifact "Completa · Escuro/Claro"):
  - **`WorkspaceSidebar`** à esquerda (largura 240, fundo `sidebar`, borda direita):
    - "orq" + nome do workspace em DM Mono;
    - o campo Comando (⌘K);
    - seção ANDARES (DM Mono 11 `muted`, espaçado): Térreo e cada andar com bolinha de status e branch em DM Mono, rolando; clique troca, clique direito abre `FloorMenu`, "Novo andar…" no fim;
    - seção USO: uma linha por provedor ("claude · 5h" e a porcentagem) com barra fina `accent`.
  - **`FloorHeader`** no topo do canvas:
    - nome do andar em Space Grotesk 22 semibold ("Térreo" sem andar) + `orq/<andar> ← <base>` em DM Mono `muted` quando é andar;
    - à direita, `FloorMenu`, "Novo terminal", abrir painel (ícone com `.help("Abrir painel…")`), zoom e "Ajustar à tela".
  - **`StatusBar`** embaixo (altura 26, DM Mono 11 `muted`, fundo `sidebar`): conexão (bolinha `accent` "conectado" ou `danger` "desconectado: motivo"), `PanelMeter`, `hostNotice`.
  - A seção PARTITURAS do mockup **não** entra aqui: quem a adiciona é o 3D.
- [ ] **Step 6: `CommandPalette`** (folha de 560 de largura, campo no topo, lista embaixo). Comandos:
  - "Novo terminal";
  - "Abrir painel…";
  - "Novo andar…";
  - "Ir para o andar ‹nome›", um por andar, mais "Ir para o Térreo";
  - "Ajustar à tela";
  - "Uso dos agentes";
  - "Preferências…" (`openSettings`).

  Cada um chama a mesma ação do botão correspondente. ⌘K abre a paleta nas duas estruturas e Esc fecha.
- [ ] **Step 7: Verificar à mão:**
  - Compacta e Completa nos dois temas, conferindo com o artifact.
  - Com o Navegador em doca numa página logada e outro no canvas, trocar a estrutura nas Preferências: a página não recarrega (o login continua), os nós ficam no lugar e as docas mantêm a largura.
  - 15 andares: a Compacta mostra 4 chips + "+11"; a Completa rola a lista.
  - ⌘K → "and" → "Ir para o andar …" → ↩ troca o andar.
- [ ] **Step 8: Commit** `feat(app): compact and full window structures with command palette`

---

### Task 6: Folhas e painéis no novo estilo

**Files:** Modify `Sources/OrqApp/TerminalSheet.swift`, `OpenPanelSheet.swift`, `FloorBar.swift` (folha "Novo andar"), `OrqApp.swift` (consentimento, banners); `Sources/OrqPlugins/MemoryPanel.swift`, `ArtifactsPanel.swift`, `DesignPanel.swift`, `DevicePanel.swift`, `DesignSystemsPanel.swift`, `BrowserPanel.swift`

**Interfaces:**
- Consumes: componentes da Task 3; `Preset.allCases` (existente); nada novo dos painéis.
- Produces: nada.

- [ ] **Step 1: Novo terminal / Editar** (artifact "Novo terminal · Escuro"):
  - **Agente:** um `ChoiceCard` por `Preset.allCases`, nome em Space Grotesk e comando em DM Mono (claude, codex, zsh, "comando"). Um preset novo, como o Cursor do 3E, aparece sem mudar a folha.
  - **Nome** e **Andar** lado a lado; **Pasta** com "Escolher".
  - **Maestro:** cartão com caixa e o texto "Pode recrutar agentes, abrir painéis e criar andares. Só alcança quem estiver ligado a ele por corda."
  - Botões: Cancelar (`secondary`) e Criar terminal / Salvar (`primary`). Avisos de reinício continuam em `attention`.
  - Lógica, validação e chaves de `UserDefaults` não mudam.
- [ ] **Step 2: Abrir painel, Novo andar, consentimento:**
  - títulos em Space Grotesk 20 semibold;
  - campos com fundo `sunken` e borda `border`;
  - botões `OrqButtonStyle`;
  - erros em `danger`.
- [ ] **Step 3: Painéis de plug-in.** Só a moldura SwiftUI muda: `PanelHeader` no topo, `PanelFooter` embaixo, itens com `orqCard`, ações com `OrqButtonStyle` e etiquetas com `OrqTag`. Conteúdo, comandos e eventos ficam iguais. Por painel, seguindo o artifact:
  - **Memória** (linha 3, "Memória · Claro"):
    - abas Revisar / Decisões / Mapa / Limpeza num seletor segmentado; Revisar mostra a contagem em `attention`;
    - busca;
    - cartões com `OrqTag` do tipo (decisão `accent`, mapa `neutral`, armadilha `attention`) + autor e quando em DM Mono;
    - Aprovar `primary`, Editar `secondary`, Descartar `quiet`;
    - rodapé "N ativas · N para revisar" e `.orq/memory`.
  - **Artifacts** (linha 3, "Artifacts · Escuro"):
    - cartão com miniatura e nome; estado em DM Mono (atual `accent`, desatualizado `attention` + borda `attention`, importando `secondary` + barra de progresso);
    - Reexportar `attention`;
    - rodapé `orq artifact add <página.html>`.
  - **Design** (linha 4, "Design · Escuro"):
    - cabeçalho com o arquivo e "sincronizado" (bolinha `accent`) + `OrqTag` de cada terminal ligado;
    - o webview do figcraft fica como está, dentro de um cartão;
    - rodapé com "Exportar para Artifacts" `primary` e "Abrir arquivo".
  - **Dispositivo** (linha 4, "Dispositivo · Claro"):
    - seletor de aparelho no cabeçalho; vídeo centralizado em fundo `sunken`;
    - Voltar / Início / Girar / Captura em `secondary`, nos que o painel já tem;
    - rodapé com o app em primeiro plano e o transporte (adb/simctl), quando o painel já sabe.
  - **Design systems** e **Navegador:** cabeçalho, rodapé e botões no estilo. A barra de URL do Navegador fica em DM Mono num campo `sunken`.
  - O que estiver no mockup mas não existir no painel (por exemplo "Mostrar toques do agente", ou a lista de telas do Design) **não** entra: é ideia para depois, fora deste plano.
- [ ] **Step 4: Verificar à mão:** cada folha e cada painel nos dois temas; navegar só pelo teclado (Tab) pela folha Novo terminal, com o anel de foco visível em cada controle; VoiceOver lê "Abrir painel…" no botão de ícone.
- [ ] **Step 5: Commit** `feat(app): restyle sheets and plug-in panels`

---

### Task 7: Docs

**Files:** Modify `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md`

- [ ] **Step 1: README** ganha a seção "Aparência":
  - Preferências (⌘,): tema Escuro / Claro / Sistema; estrutura Compacta / Completa; fonte do terminal;
  - ⌘K;
  - `scripts/fetch-fonts.sh` antes de `bundle-app.sh` (sem ele, fontes do sistema).
- [ ] **Step 2: Roteiro:** status da linha "3R — Redesign visual" passa a "merged".
- [ ] **Step 3: Commit** `docs: appearance preferences and redesign`
