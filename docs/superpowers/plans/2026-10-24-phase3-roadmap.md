# Fase 3 — Roteiro de planos

**Spec:** `docs/superpowers/specs/2026-10-24-phase3-design.md` (aprovado pelo usuário em 2026-10-24).

| Plano | Entrega | Depende de | Status |
|---|---|---|---|
| 3A — Registro de trabalho | Trabalhos/tarefas/subagentes/shells no daemon, alimentados por hooks do Claude Code e `orq work …`; fecha por merge/agente/usuário; histórico. Exportar/importar os dados do Orq (backup). | v1, 2E, 2F | `2026-10-24-plan-3a-work-registry.md` ✅ mergeado (3dbdc95) |
| 3B — Painel Trabalho + chat | Painel de doca com status por trabalho, alertas, conversa (`@terminal` / Maestro), perguntas de status sem tokens, aprovações com checagem de pendência, "Recolocar no trilho". | 3A | `2026-10-24-plan-3b-work-panel-chat.md` ✅ mergeado (e4926ce) |
| 3C — Resumo do trabalho | Feito / para depois / não feito, determinístico sempre; reescrita e perguntas livres com FoundationModels no macOS 26; vai para a Memória ao fechar. | 3A (3B para mostrar) | `2026-10-24-plan-3c-work-summary.md` ✅ mergeado (fcf048f) |
| 3D — Partituras | Prontas de fábrica, salvar do canvas, aplicar tudo-ou-nada (com ou sem andar), arquivo de partitura com aviso de confiança; Maestro salva e aplica. | v1 | `2026-10-24-plan-3d-partituras.md` ✅ mergeado (e4926ce) |
| 3R — Redesign visual | Temas Escuro/Claro/Sistema, estruturas Compacta/Completa, Space Grotesk + DM Mono, Preferências (⌘,), ⌘K, folhas e painéis no novo estilo. Só UI. Fazer antes das telas do 3B e do 3D, que já nascem com os componentes de `OrqTheme`. | v1, 2E, 2F | `2026-10-21-plan-3r-redesign.md` ✅ mergeado (5050e15) |

**Depois da Fase 3** (decisão do usuário em 2026-10-24):

| Plano | Entrega | Depende de | Status |
|---|---|---|---|
| 3E — Preset Cursor | `cursor-agent` como preset (como o Codex): lançar, recrutar, `ask` com resposta por ociosidade se não houver hook; começa por spike dos hooks do CLI sem tocar configuração global; painel de uso provavelmente sem dados; registro de trabalho só por comando explícito. | 3A | `2026-10-24-plan-3e-cursor-preset.md` (escrito) |
| 4R — Collie | Orq vira Collie (app, daemon, CLI/MCP, módulos, dados, variáveis) com migração dos dados existentes, marca nova e vocabulário de pastoreio (Pastor, guia, cercado, pasto, rebanho). | 3R | `2026-10-22-plan-4r-collie-rename.md` (branch `plan-4r`, aguardando merge) |
