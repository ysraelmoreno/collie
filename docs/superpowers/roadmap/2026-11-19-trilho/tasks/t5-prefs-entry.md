# T5 Entradas das Preferências na janela principal

Leia primeiro o `README.md` desta pasta. Depende de T4 (`mainView`, `MainViewState`, aba Preferências).

Código: `Sources/CollieApp/CollieApp.swift` (a cena `Settings`, o `CommandGroup`, a paleta `paletteCommands`, o `onReceive` de `collieOpenPreferences`), `Sources/CollieApp/Shell.swift` (engrenagem, `ShellContext.openPreferences`), `Sources/CollieApp/PreferencePage.swift` (`requestKey`, `requested(_:)`), `Sources/CollieApp/UpdateInstallSheet.swift` e `Sources/ColliePlugins/DesignPanel.swift` (quem posta `collieOpenPreferences`; não mudar o contrato da notificação).

## Fazer

1. **Só na estrutura Completa** (`structure == .full`), as entradas abrem a aba Preferências na janela principal; na Compacta elas continuam abrindo a janela de Ajustes (`openSettings()`), sem mudança. As entradas: o menu do app "Ajustes…/Preferências…" (⌘,) — substitua o item padrão por um `CommandGroup(replacing: .appSettings)` com o atalho `⌘,` que chama `openPreferences()`; o comando "Preferências…" da paleta; a engrenagem do trilho (`ctx.openPreferences`); e a notificação `collieOpenPreferences` (continua gravando a página pedida em `PreferencePage.requestKey` e agora também mostra a aba).
2. **Mantenha** a cena `Settings { PreferencesView(client:) }` (a Compacta a usa) e o `openSettings`; o `⌘,` e os demais pontos de entrada escolhem o destino pela estrutura atual. Um único ponto de decisão (uma função `openPreferences()` no `ContentView`) usado por todos. Se a janela principal estiver fechada quando a notificação chegar, o app reabre a janela principal já na aba (pelo mecanismo de janela que o app já usa; se não houver, basta guardar o pedido e abrir as Preferências assim que a janela aparecer).
3. **Esc** na aba Preferências volta ao canvas, sem roubar o Esc de campos de texto, de sheets abertas, nem do terminal (o terminal não recebe teclas enquanto o canvas está escondido). Clicar na aba Canvas também volta. Voltar não reseta a página escolhida: reabrir mostra a última página.
4. `PreferencesView` continua aplicando o tema ao mudar (`CollieApp.applyTheme()`), agora sem depender de ser a janela de Ajustes.
5. Nenhuma mudança de comportamento nas páginas em si.

## Testes (escrever antes)

Em `MainViewTests`: o pedido de página (`PreferencePage.requested("desenho")`) mais `show(.preferences)` deixa a aba aberta; `back()` depois dela volta; reabrir não limpa a página lembrada (se a lógica estiver em `MainViewState`, teste ali). Em `PreferencePageTests`, o que já cobre `requested(_:)` continua verde.
