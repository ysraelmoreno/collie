# T1 Modelo da árvore de agentes

Leia primeiro `docs/superpowers/roadmap/2026-11-19-trilho/README.md`. Aqui só a lógica pura, sem SwiftUI.

Código: crie `Sources/CollieApp/AgentTree.swift` e `Tests/CollieAppTests/AgentTreeTests.swift`. Dados de entrada que já existem: `TerminalRecord` (`CollieCore/Workspace.swift`: `id`, `name`, `preset`, `isShepherd`, `paddockId`), `Connection` (as coleiras, em `DaemonClient.connections`), `StatusBadge` (`DaemonClient.badges`, o estado de cada terminal), e os cartões abertos de `DaemonClient` (`accessCards`, `leashRequests`, `appCards`).

## Fazer

1. Um tipo `AgentTree` com uma função estática pura `rows(terminals:connections:badges:pending:paddock:collapsed:) -> [Row]`, sem ler `DaemonClient` (recebe os valores). `paddock`: só os terminais desse cercado (`nil` = Pasto). `pending: [UUID: Int]` é o número de cartões abertos por terminal.
2. `Row`: `id: UUID`, `name`, `preset` (para o chip), `depth` (0 ou 1), `status` (reaproveite o enum/valor que `StatusBadge` já dá; não invente outro), `pending: Int`, `isParent: Bool`, `isCollapsed: Bool`.
3. Ordem: cada Pastor do cercado, seguido dos terminais ligados a ele por coleira (profundidade 1, na ordem de criação); depois os terminais restantes, na raiz, na ordem de criação. Um terminal ligado a dois Pastores aparece sob o primeiro; um terminal nunca aparece duas vezes. Sem Pastor no cercado: lista plana, profundidade 0.
4. `collapsed: Set<UUID>`: os filhos de um Pastor recolhido não entram na lista; o Pastor continua, com `isCollapsed == true`.
5. Uma função `AgentTree.pending(accessCards:leashRequests:appCards:) -> [UUID: Int]` que conta por terminal os cartões abertos (use os campos que ligam cada tipo de cartão ao terminal; um cartão sem terminal conhecido não conta).
6. Nada de SwiftUI, AppKit nem `DaemonClient` neste arquivo.

## Testes (escrever antes) — `AgentTreeTests`

Pastor com dois filhos e um terminal solto (ordem e profundidades); recolher esconde só os filhos; sem Pastor vira lista plana; terminal ligado a dois Pastores aparece uma vez; terminais de outro cercado ficam fora; Pasto (`nil`); contagem de cartões por terminal; cartão sem terminal conhecido não conta.
