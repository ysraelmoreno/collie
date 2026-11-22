# Tarefa D1b: painel de device com moldura

Faça a **Parte 2** (itens 5 a 12) de `docs/superpowers/roadmap/2026-11-22-device-molduras/prd-d1-molduras.md`.
Leia o PRD inteiro antes; o design aprovado está em `docs/pages/painel-device-molduras/index.html` (abra o HTML e
siga medidas, recortes e rodapé dele).

- `DeviceFrame.Kind` já existe em `Sources/CollieDevice/DeviceFrame.swift`. Use-o; não edite esse arquivo (a tarefa
  D1a, em paralelo, acrescenta funções nele). Leia o tipo de `panel.state["frame"]` (`.string(rawValue)`); ausente ou
  desconhecido → `.bare`.
- Escopo: só `Sources/ColliePlugins/DevicePanel.swift`, `Sources/ColliePlugins/DeviceBezel.swift` (novo),
  `Tests/ColliePluginsTests/DevicePanelTests.swift`, `Tests/ColliePluginsTests/DeviceBezelTests.swift` (novo),
  `docs/feature-map.md`, `CHANGELOG.md`.
- Testes novos na suíte `DeviceBezelTests` com os casos do Aceite. Se mudar a assinatura de `devicePoint`/`videoRect`,
  atualize `letterboxMapping` em `DevicePanelTests.swift`; os testes que já existem lá continuam passando.
- Toque mapeado pelo retângulo da tela da moldura; `footerHeight` constante.

Aceite: o do PRD (parte `DeviceBezelTests`). Regras do repo no rodapé do PRD.
