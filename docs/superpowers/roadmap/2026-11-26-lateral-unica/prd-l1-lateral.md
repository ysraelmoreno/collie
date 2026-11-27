# PRD L1: lateral única

PRD geral: `README.md`. Spec: seção "Lateral". Onda 1. Protótipo: `docs/pages/remanejamento/2-uma-lateral.html`.

## Problema

Trilho com letras soltas + painel de contexto com seis seções sempre abertas. Ninguém sabe qual cercado é qual nem
onde estão as coisas.

## Fazer (novos `Sources/CollieApp/Sidebar.swift`, `Sources/CollieApp/SidebarModel.swift`,
`Tests/CollieAppTests/SidebarModelTests.swift`; nenhum outro arquivo — L3 monta a lateral na janela)

1. **`SidebarModel`** (puro, como `AgentTree`: recebe valores do `DaemonClient`, nunca o client):
   - `paddockRows(paddocks:, terminals:, badges:, pending:, current:) -> [PaddockRow]`: Pasto + cercados, nome,
     ramo, `status` em texto (`"espera você"` se algum agente tem pedido; `"n trabalhando"`; `"parado"`), `needs` (nº
     de pedidos), `isCurrent`. Ordem: a de hoje no trilho.
   - `tree(...) -> [TreeRow]`: os agentes do cercado atual via `AgentTree.rows` (reuse, não reescreva) e, embaixo de
     cada agente, os painéis que ele abriu (`createdBy`); painéis sem dono no fim. O papel Pastor vira `role`.
   - `initials(_ name:) -> String`: duas letras para a lateral recolhida (`collie-general-working` → `CG`,
     `idiomas` → `ID`, `Pasto` → `PA`).
2. **`Sidebar: View`**, `init(ctx: ShellContext, collapsed: Binding<Bool>)`, largura 240 pt (recolhida 56 pt):
   - topo: botão primário "＋ Novo agente" (menu: Terminal simples → `ctx.newTerminal`, Painel… → `ctx.openPanel`,
     A partir de rebanho… → `ctx.openHerds(nil)`);
   - rótulo discreto "Cercados" (sem caixa-alta espaçada) com ＋ que cria cercado (ação de hoje do trilho);
   - uma linha por cercado: ponto + nome + estado em texto; clicar troca de cercado (ação de hoje);
   - o cercado atual expandido: cabeçalho com nome e ramo em mono (completo no `.help`), botão ⋯ com o menu de hoje
     do cercado mais Lotes… e Fábrica (com uma frase do que faz; reuse o que `ContextPanel` chama) ; abaixo a árvore:
     agente (ponto + nome + estado; tag "Pastor" só aqui), filhos recuados, painéis do agente com ícone; clicar foca o
     nó (`ctx.focus`), duplo clique edita (`ctx.edit`), recolher Pastor como hoje;
   - recolhida: só iniciais em quadrado, número quando `needs > 0`, nome no `.help`; ⌘\ alterna (o atalho fica num
     `Button` com `.keyboardShortcut("\\")`);
   - `footer: AnyView? = nil` desenhado no pé (L2 preenche).
   - Acessibilidade: cada linha com label "nome, estado"; estado nunca só por cor.

## Aceite

`SidebarModelTests`: estados em texto (pedido vence trabalhando); Pasto incluído; painel aparece sob quem o abriu e
sem dono vai ao fim; Pastor com filhos aninhados (delegue a `AgentTree`, só confira a integração); iniciais (nome
curto, com hífen, com acento, uma letra); `needs` soma pedidos dos agentes do cercado.

## Check

`lockf -k .collie/build.lock swift test --disable-sandbox --filter SidebarModelTests`

## No app real (dono, fim da onda 3)

Lateral mostra os cercados por nome com estado; o atual em árvore; ⌘\ recolhe e volta sem mexer no canvas; o ⋯ tem
Lotes e Fábrica; nenhuma seção de Rebanhos/Lotes/Fábrica/Laços sempre aberta.
