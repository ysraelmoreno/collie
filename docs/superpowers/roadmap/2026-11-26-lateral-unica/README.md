# PRD geral: lateral única

Data: 2026-11-26. Estado: spec aprovada pelo dono. Nada construído.
Spec: `docs/superpowers/specs/2026-11-26-lateral-unica-design.md`. Protótipo: `docs/pages/remanejamento/2-uma-lateral.html`
(abra e use as "Notas de UX": a tabela "o que saiu da tela e para onde foi" é o checklist de aceite visual).

## Problema

Informação demais ao mesmo tempo e caminho confuso para quem não conhece orquestração de agentes. O dono quer a
estrutura atual (lateral + canvas), mais sóbria.

## Objetivo

Uma lateral só (cercados por nome, o atual em árvore), canvas na janela inteira, terminal com nome e estado, laço
preso ao terminal que o roda, pedidos perto de quem pediu, e um primeiro uso que se explica sozinho.

## Não-objetivos

Daemon, protocolo, funções novas, temas/cores/fontes (usa a paleta ativa), canvas fullscreen, iOS.

## Anti-objetivos

- Esconder um pedido de sandbox: todo pedido aparece no terminal que pediu **e** no "Precisa de você".
- Recriar terminais ou perder zoom/posições ao abrir Preferências, recolher a lateral ou trocar de cercado.
- Cor como único sinal de estado: sempre ponto + palavra.

## PRDs e ondas

Portão comum: `scripts/ci/lint.sh && scripts/ci/check-architecture.sh`, e as suítes do próprio PRD.

| Onda | PRD | O quê | Arquivos (donos exclusivos na onda) |
|---|---|---|---|
| 1 | [L1](prd-l1-lateral.md) | lateral: lista de cercados, árvore do atual, ⋯ do cercado, ＋ Novo agente, recolher | novos `Sidebar.swift`, `SidebarModel.swift` + testes |
| 1 | [L4](prd-l4-cabecalho-terminal.md) | cabeçalho do terminal enxuto, cartão de pedido dentro do terminal | `TerminalNodeView.swift`, `AccessViews.swift` |
| 1 | [L5](prd-l5-laco-flutuante.md) | laço flutuante preso ao terminal + pílula | `LoopSection.swift`, `LoopsSheet.swift`, novo `LoopFloat.swift`, `CanvasViewport.swift` |
| 2 | [L3](prd-l3-casca.md) | casca: monta a lateral, tira abas e barra de status, barra flutuante, Preferências em folha, remove Completa/Compacta | `Shell.swift`, `CollieApp.swift`, `MainView.swift`, `PreferencesView.swift`, `PreferencePage.swift`, `DockView.swift`, `CollieTheme/Appearance.swift`, `PaddockRail.swift`, `ContextPanel.swift` (apagar) |
| 2 | [L2](prd-l2-pe-lateral.md) | pé da lateral: Precisa de você (n), uso, Preferências, desconexão | novo `SidebarFooter.swift`; `Sidebar.swift` (só o encaixe); `UsagePopover.swift` |
| 3 | [L6](prd-l6-primeiro-uso.md) | primeiro uso, ⌘K com as entradas que saíram da tela, tour fora do trilho | `FeatureTour*.swift`, `CommandPalette.swift`, `HerdsSheet.swift` |

Interfaces entre PRDs (nomes fixos):
- L1 produz `struct Sidebar: View { init(ctx: ShellContext, collapsed: Binding<Bool>) }` e reserva o pé com
  `footer: AnyView?` vazio até L2.
- L5 produz `LoopFloat` desenhado pelo `CanvasViewport` ao lado do terminal dono do laço.
- L3 usa `Sidebar` e chama `ctx.openPreferences()` abrindo a folha.

## Verificação que os testes não cobrem

Tudo aqui muda o que se vê. Cada PRD termina com a seção "No app real", feita pelo dono num `build/Collie.app`
(`scripts/bundle-app.sh`) no fim da onda 3. Quem implementa não abre o app.

---
Regras do trabalho em paralelo (vários agentes no MESMO cercado): só edite os arquivos do seu PRD; precisou de
outro, anote no relatório. Build e teste sempre com `lockf -k .collie/build.lock swift build|test --disable-sandbox …`,
`.build` padrão. Faça build do produto durante o trabalho; teste só as suas suítes **uma vez no fim**. Erro de
compilação em arquivo que não é seu = outro agente no meio; espere e rode de novo. Commit só dos seus arquivos com
pathspec (`git commit -m … -- <arquivos>`), mensagem convencional terminando com
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Nunca `git add -A`, `git stash`, `git reset`, push.
Textos que o usuário vê: `tr("pt", "en")` com `import CollieCore`. Sem dependência nova, sem `Task.sleep`, `try!`,
`@unchecked Sendable` novos.
