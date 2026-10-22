# Fase 2 — Roteiro de planos (Design)

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` §7.1–7.3 (Design, Design Systems, Artifacts, importar HTML).
**Spike:** `docs/superpowers/spikes/2026-10-20-figcraft/REPORT.md` — caminho **(a)** aprovado pelo usuário em 2026-10-20: `figcraft-server` local + UI WASM do figcraft em WKWebView + clientes `figcraft-cli mcp` headless na mesma sessão (uma fonte ao vivo; sem trocar de motor).

| Plano | Entrega | Depende de | Status |
|---|---|---|---|
| 2A — Motor de design + painel Design | Build fixado do figcraft v0.7.0 (sem marca ArtCraft, sem servidor público, com fontes), servidor supervisionado pelo daemon, comandos `design.*` para agentes (rodar comando/lote, inspecionar, screenshot, exportar), painel Design com a UI ao vivo. | Fase 1 | ✅ `2026-10-20-plan-2a-design-engine.md` (merged) |
| 2B — Design Systems | Biblioteca de design systems (arquivos figcraft com variáveis/modos/componentes), ativo por workspace e por andar, aplicar com desfazer, histórico de versões, decisão gravada na Memória. | 2A | ✅ `2026-10-21-plan-2b-design-systems.md` (merged) |
| 2C — Artifacts + export HTML de verdade | Pós-processador do export (semântica `h1/section/ul/a`, reset, fallback de fontes, modos via `[data-theme]`, responsivo básico), painel Artifacts (miniatura, origem, desatualizado, reexportar, abrir no Navegador). | 2A, 2B | ✅ `2026-10-22-plan-2c-artifacts-export.md` (merged) |
| 2D — Importar HTML como tela | WKWebView invisível lê DOM/estilos → comandos figcraft num único `batch`; HTML original arquivado como origem; caso de teste: landing page real do usuário. | 2A, 2C | ✅ `2026-10-23-plan-2d-html-import.md` (merged) |
| 2E — Pendências da v1 | Links por agentes (`text.link` validado), eventos de plug-in nos painéis do app, artifact por página, importação liga cores ao design system, painel Design entra sem "Entrar", WebGPU com WebGL2 de reserva. | 2C, 2D | ✅ `2026-10-24-plan-2e-v1-followups.md` (merged) |
| 2F — Ambiente dos agentes | Agentes lançados com o ambiente do shell interativo do usuário (`$SHELL -ilc`, cache; `node` do nvm nos hooks globais); MCP `orq` por terminal filtrado pelo alcance; orientação "você está no Orq" no início de sessão. Roda antes do 3A. | 2E | `2026-10-21-plan-2f-agent-environment.md` ✅ mergeado (b5cf858) |
| 2G — Emuladores Android desligados | `device.list` mostra AVDs instalados e desligados (`avd:<nome>`); abrir o painel liga o emulador e espera o boot (até 180 s); o Orq nunca o desliga. | 2E | `2026-10-21-plan-2g-android-emulators.md` ✅ mergeado (5050e15) |
