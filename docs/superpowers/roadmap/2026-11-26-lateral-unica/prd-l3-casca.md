# PRD L3: casca da janela

PRD geral: `README.md`. Spec: "Canvas", "Sai da tela", decisões 2 e 3. Onda 2 (usa `Sidebar` de L1).

## Problema

Abas com uma só aba útil, barra de status com contadores internos, duas estruturas (Completa/Compacta) e
Preferências trocando o canvas.

## Fazer (`Shell.swift`, `CollieApp.swift`, `MainView.swift`, `PreferencesView.swift`, `PreferencePage.swift`,
`DockView.swift`, `CollieTheme/Appearance.swift`; apagar `PaddockRail.swift` e `ContextPanel.swift` e mover para
`Sidebar*`/`SidebarFooter` o que ainda for usado; testes afetados: `ShellTests`, `MainViewTests`,
`PaddockRailTests`, `ContextPanel*Tests`, `PreferencePageTests`)

1. **Uma estrutura**: `Shell` = `Sidebar` + canvas. Sai `WindowStructure` (e a escolha em Aparência). Migração: quem
   tinha `compact` salvo começa com a lateral recolhida (`@AppStorage("sidebar.collapsed")`); a chave velha é lida uma
   vez e apagada.
2. **Sem abas, sem barra de status**: sai `MainTabs` e `StatusBar`. A barra flutuante fina (canto superior direito
   do canvas, abaixo dos semáforos) tem: campo ⌘K (o `CommandField` de hoje), zoom − n% +, Ajustar, minimapa
   (desligado por padrão, `@AppStorage`). Semáforos: a lateral começa abaixo deles (`lightsInset`).
3. **Diagnóstico**: nova página Preferências › Diagnóstico com o que a barra de status mostrava (conexão, memória do
   processo, contadores por tipo de painel). Mesmo texto, agora explicado em uma linha.
4. **Preferências em folha**: `ctx.openPreferences` e ⌘, abrem `.sheet` grande (≈ 860×620, redimensionável) com a
   navegação de hoje; Esc e "Fechar" fecham. Sai `MainViewState`/`MainView` e o modo embutido. O canvas continua
   montado (zoom, posições, terminais intactos). Uma página pedida (`.preferences(.plugins)` do tour) abre a folha
   nela.
5. Os semáforos, o arrastar da janela pela área vazia e o fullscreen do canvas continuam.

## Aceite

Testes atualizados e passando; novo teste da migração (`compact` salvo → recolhida, chave apagada; sem chave →
expandida); `PreferencePageTests` cobre Diagnóstico; nenhuma referência a `WindowStructure`, `MainTabs`,
`StatusBar`, `PaddockRail`, `ContextPanel` sobra (`rg` vazio).

## Check

`lockf -k .collie/build.lock swift test --disable-sandbox --filter '(ShellTests|SidebarMigrationTests|PreferencePageTests|FeatureTourTests)'`
mais lint e arquitetura.

## No app real

Sem abas e sem barra embaixo; ⌘, abre a folha por cima do canvas, Esc fecha e nada mudou no canvas; barra flutuante
faz zoom, Ajustar e minimapa; quem estava em Compacta abre com a lateral recolhida.
