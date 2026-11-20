# PRD T2: paleta ativa trocável e aplicação ao app inteiro

PRD geral: `README.md` desta pasta. Design: seção "How it applies". Depende de T1.

## Problema

`CollieColor` escolhe entre duas constantes. Para um tema do usuário valer, a paleta precisa poder ser trocada com o
app aberto, e tudo que já está na tela precisa mudar de cor sem ser recriado.

## Primeira tarefa: provar o redesenho

Antes de qualquer outra coisa, descobrir e registrar neste PRD (seção "Resultado da prova", no fim) como fazer a
tela inteira refletir a paleta nova **sem piscar e sem recriar terminais**, com a aparência (claro/escuro) igual
antes e depois. Candidatos, do mais simples ao mais invasivo:

1. marcar as janelas para redesenho (`needsDisplay` na árvore de views; `viewDidChangeEffectiveAppearance` chamado
   à mão onde há cor de `CALayer`);
2. uma notificação própria (`collieThemeChanged`) que cada view com cor fixa já observa;
3. trocar a aparência da janela e voltar (pisca: só se nada acima servir).

SwiftUI: cores `Color(nsColor:)` dinâmicas precisam ser resolvidas de novo; verificar se o redesenho da janela
basta ou se a raiz precisa de um valor de ambiente que muda (sem trocar o `id` da raiz, que recria os terminais).

Se nenhum caminho funcionar sem recriar terminais, parar e relatar: isso muda o design.

## Fazer

Arquivos: `Sources/CollieTheme/Palette.swift` e `Appearance.swift`; novo `Sources/CollieTheme/ActivePalette.swift`;
`Sources/CollieApp/CollieApp.swift` (`applyTheme`); `Sources/CollieApp/TerminalNodeView.swift` e
`PanelNodeView.swift` (cores fixas); `Sources/ColliePlugins/WebPluginPanel.swift` (`themeJSON`); testes em
`Tests/CollieThemeTests/` e `Tests/ColliePluginsTests/`.

1. **`ActivePalette`**: guarda a paleta escura e a clara em uso (padrão: as embutidas), protegida para leitura de
   qualquer thread; `set(dark:light:)` e `reset()`. `CollieColor` passa a ler daqui. `Palette.dark`/`.light`
   continuam sendo as embutidas.
2. **Escolha de tema**: `appearance.theme` aceita `dark`, `light`, `system` e `custom:<id>`. Um tipo novo
   (`ThemeSelection`) substitui o uso de `ThemeChoice` onde a escolha é lida; `custom:<id>` com id inválido lê como
   `dark`. `AppearanceSettings.normalize` não apaga um `custom:<id>` válido.
3. **Aplicar** (`applyTheme(selection:theme:)`): embutido → `ActivePalette.reset()` e a aparência de hoje;
   personalizado → a paleta do lado de `extends` vira `theme.palette`, a outra fica embutida, e a aparência do app
   vira a de `extends`. Depois, o redesenho da prova. Um `custom:<id>` sem tema carregado aplica `dark`.
   (Quem carrega o tema do disco é T3; aqui `applyTheme` recebe o `ThemeFile` já lido.)
4. **Terminais**: `applyColors` roda de novo para cada terminal aberto depois da troca; nenhum terminal é recriado
   (o processo e o scrollback continuam).
5. **Cores de `CALayer`** postas à mão (bordas e fundos dos nós) são refeitas.
6. **Páginas de plug-in e Prévia**: `WebPluginPanel.themeJSON` usa a paleta ativa e o evento `collie-theme` é
   emitido na troca.

## Aceite

- `ActivePaletteTests`: depois de `set`, `CollieColor.accent` resolvido sob a aparência escura é a cor nova, e sob
  a clara continua a embutida; `reset` volta; leitura concorrente não quebra.
- `AppearanceTests`: `custom:tinta` é lido e preservado por `normalize`; `custom:../x` e `custom:` leem `dark`.
- `WebPluginPanelTests`: `themeJSON` traz a cor da paleta ativa.
- **No app real** (registrar o resultado aqui): com dois terminais abertos e um comando rodando em um deles,
  aplicar por código um tema de teste; canvas, barra lateral, Preferências, terminal (fundo, texto, cursor) e uma
  página de plug-in mudam; o comando segue rodando; nada pisca.

## Check

```
swift test --disable-sandbox --filter 'ActivePaletteTests|AppearanceTests|PaletteTests|WebPluginPanelTests'
```

## Resultado da prova

**Não provado.** Quem implementou não podia abrir o app, então nada abaixo foi visto na tela: é o caminho
implementado, não um caminho comprovado. O dono confere pelo passo a passo no fim desta seção.

### O que foi implementado (caminho 2 combinado com o 1; SwiftUI por valor de ambiente)

- `ActivePalette` (`Sources/CollieTheme/ActivePalette.swift`): guarda a paleta escura e a clara em uso, atrás de um
  `OSAllocatedUnfairLock`; `set(dark:light:)` e `reset()`. `CollieColor` lê daqui a cada resolução de cor.
- `Notification.Name.collieThemeChanged`, postada por `CollieApp.applyTheme(selection:theme:)` depois da troca.
  Observam (por seletor, que sai sozinho ao desalocar): `TerminalNodeView` (refaz `applyChrome` e `applyColors`
  de cada terminal aberto, sem recriar nada), `PanelNodeView` (`applyChrome`) e `WebPluginPanel` (reemite o
  `collie-theme` com `themeJSON`, que agora lê `ActivePalette`).
- Caminho 1 junto: depois de postar, `applyTheme` percorre `NSApp.windows` e, em cada view da árvore, chama
  `viewDidChangeEffectiveAppearance()` à mão e marca `needsDisplay`. Cobre as views com cor de `CALayer` em arquivos
  que o PRD não lista (`DevicePanel`, `DiagramPanel`, `DesignPanel`, `PreviewPanel`). Efeito colateral aceito: nós
  de terminal e páginas de plug-in refazem as cores duas vezes (notificação e chamada à mão); é idempotente.
- SwiftUI: `EnvironmentValues.collieThemeRevision` (um inteiro). `CollieApp` guarda `@State themeRevision`, soma 1 a
  cada `collieThemeChanged` e injeta o valor na janela principal e em Ajustes. O `id` da raiz não muda.
- `ThemeSelection` (`dark`, `light`, `system`, `custom(id)`) substitui `ThemeChoice` em `AppearanceSettings.theme`;
  `custom:<id>` inválido lê como `dark`, e `normalize` preserva um válido. `ThemeChoice` continua, pois
  `PreferencesView` ainda o usa (T5 troca).
- Descartado: trocar a aparência da janela e voltar (pedido do dono: pisca).

### O que NÃO foi provado no app

1. Que a notificação e a chamada manual bastam para refazer as cores dos nós, das barras e dos terminais sem
   piscar. Nada foi aberto nem compilado por quem escreveu (o Pastor compila e roda os testes depois).
2. **Principal risco:** que as views SwiftUI mudem de cor. `Color(nsColor:)` de uma cor dinâmica só é resolvida de
   novo se o `body` da view rodar de novo, e o `body` só roda de novo se ler algo que mudou. O valor de ambiente só
   invalida as views que o leem (`@Environment(\.collieThemeRevision)`), e nenhuma o lê ainda. Se, na conferência,
   a barra lateral ou Preferências não mudarem, o conserto é pequeno e conhecido: ler o valor nas views raiz de
   cada área (por exemplo `let _ = themeRevision` no início do `body`), ainda sem mexer no `id`. Isso muda
   arquivos fora da lista deste PRD, por isso não foi feito.
3. Que `viewDidChangeEffectiveAppearance()` chamado à mão em toda a árvore, inclusive dentro de `NSHostingView`,
   não tenha efeito estranho (a suspeita é que não tem: é um gancho vazio no `NSView`).
4. Que a página de plug-in receba os tokens novos uma só vez e sem piscar (ela os recebe duas vezes: notificação
   e chamada à mão).
5. Que o terminal em execução mantenha processo e scrollback (a troca só atribui cores, nunca recria o
   `NodeTerminal`; conferir mesmo assim).
6. `PreferencesView` ainda lê `appearance.theme` como `ThemeChoice`: com `custom:<id>` gravado, o seletor de hoje
   fica sem opção marcada até T5.
7. `applyTheme()` sem argumentos (o que `onAppear`, `onChange` e Preferências chamam) passa `theme: nil`: um
   `custom:<id>` aplica `dark` até T3 carregar o tema do disco e chamar `applyTheme(selection:theme:)`.

### Passo a passo para o dono conferir

Pré-requisito: build deste ramo instalado. Como T3 ainda não liga o arquivo ao app, a troca é feita por código de
teste: em `CollieApp.init` (temporário, não commitar), logo depois de `Self.applyTheme()`, e depois também a partir
de um botão ou atalho temporário para trocar com o app já aberto, chamar
`Self.applyTheme(selection: .custom("teste"), theme: ThemeFile(name: "Teste", extends: .dark, colors: ["accent": RGB(hex: 0xFF00AA), "sunken": RGB(hex: 0x002200), "text": RGB(hex: 0xFFFF00), "surface": RGB(hex: 0x220000)]))`.

1. Abrir o app com dois terminais; em um, rodar `while true; do date; sleep 1; done`; no outro, escrever algo.
2. Disparar a troca com o app aberto. Observar: o fundo do terminal fica verde-escuro, o texto amarelo, o cursor e a
   seleção rosa; a borda do nó selecionado fica rosa; o fundo dos nós (surface) fica vinho.
3. Confirmar que o `date` segue imprimindo, que o scrollback do outro terminal continua e que nada piscou (a tela
   não passou por claro nem por branco).
4. Ver a barra lateral, a barra de cima, o canvas e Preferências (⌘,): todos devem refletir `surface`/`accent`
   novos. **Se algum ficar na cor antiga, é o risco 2 acima**: anotar qual e avisar.
5. Abrir uma página de plug-in e uma Prévia: devem mudar de cor (tokens `--collie-accent` etc.).
6. Disparar de volta `applyTheme(selection: .dark, theme: nil)`: tudo volta ao embutido, também sem piscar.
7. Repetir com `extends: .light` e `.custom` claro: a aparência do app vira clara; ao voltar para `.dark`, escura.
8. Registrar aqui o que mudou ou não, e remover o código temporário.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`, `try!` ou `@unchecked Sendable` novos (a catraca de `scripts/ci/lint.sh` recusa). Commit com
mensagem convencional, só dos seus arquivos; nada de push.
