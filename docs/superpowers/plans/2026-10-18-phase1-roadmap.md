# Fase 1 — Roteiro de planos

**Spec:** `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md` (Fase 1: núcleo + Memória + Navegador).
**Referência comportamental:** a análise de referência (local, não publicada).

A fase 1 cobre subsistemas independentes; cada um tem plano próprio e entrega software testável. Os planos posteriores são escritos quando o anterior fecha, porque consomem as interfaces que ele fixa.

| Plano | Entrega | Depende de | Status |
|---|---|---|---|
| **1A — Daemon, protocolo e terminais** | `orqd` headless: PTYs, scrollback com teto, auth por token, `list/ask/check` com resposta por hooks (fallback ocioso), CLI `orq` + `orq mcp`. Testável sem UI. | — | ✅ `2026-10-18-plan-1a-daemon.md` (merged) |
| 1B — App shell e canvas | App SwiftUI/AppKit: canvas (pan/zoom/minimap), nós de terminal (SwiftTerm ligado ao PTY do daemon), cordas, presets, reconexão ao daemon, reinício do daemon, avisos de atenção. | 1A | ✅ `2026-10-19-plan-1b-app-canvas.md` (merged) |
| 1C — Maestro e andares | Credencial de admin do Maestro; comandos Maestro (recruit/dismiss/connect/notify/open-panel), andares via git worktree + land, painel de uso dos agentes. (open-panel → 1D) | 1A, 1B | ✅ `2026-10-19-plan-1c-maestro-floors.md` (merged) |
| 1D — Sistema de plug-ins + Navegador | Registro de plug-ins (painéis doca/canvas, comandos → CLI/MCP, eventos), regras de acesso por corda/doca, Navegador (WKWebView controlável), `panel.open` do Maestro. | 1A, 1B | ✅ `2026-10-19-plan-1d-plugins-browser.md` (merged) |
| 1E — Memória | Store markdown em `<repo>/.orq/memory` + índice SQLite derivado, comandos de memória, injeção (início de sessão + por assunto), painel Revisar/Decisões/Mapa/Limpeza, limpeza reversível. | 1A, 1D | ✅ `2026-10-19-plan-1e-memory.md` (merged) |
| 1F — Dispositivos Android | Plug-in device: vídeo scrcpy + comandos adb, no daemon. + editar terminal, menu do canvas (pedido 2026-10-19). | 1D | ✅ `2026-10-19-plan-1f-android.md` (merged) |
| 1G — Simulador iOS | Plug-in device: simctl + AXe (vídeo por `axe stream-video`, decisão do usuário 2026-10-19). | 1D, 1F | ✅ `2026-10-19-plan-1g-ios-simulator.md` (merged) |

**Codinome [call]:** `Orq` (CLI `orq`, daemon `orqd`, pasta `.orq/`, env `ORQ_*`). Trocar o nome antes de iniciar 1A é um find/replace; depois fica caro.
