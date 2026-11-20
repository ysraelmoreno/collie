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

(a preencher por quem implementar: o caminho escolhido e o que foi descartado, com o motivo)

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`, `try!` ou `@unchecked Sendable` novos (a catraca de `scripts/ci/lint.sh` recusa). Commit com
mensagem convencional, só dos seus arquivos; nada de push.
