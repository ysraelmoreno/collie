# Tarefa D1a: tipo de moldura no daemon

Faça a **Parte 1** (itens 1 a 4) de `docs/superpowers/roadmap/2026-11-22-device-molduras/prd-d1-molduras.md`.
Leia o PRD inteiro antes; o design está em `docs/pages/painel-device-molduras/index.html`.

- `DeviceFrame.Kind` já existe em `Sources/CollieDevice/DeviceFrame.swift` (commitado). Não renomeie os casos;
  acrescente as funções `android(hwDeviceName:emulator:)` e `ios(deviceTypeIdentifier:)` no mesmo arquivo.
- Escopo: só `Sources/CollieDevice/**`, `Sources/CollieDaemonKit/**`, `Tests/CollieDeviceTests/**`,
  `Tests/CollieDaemonKitTests/**`. Não toque em `ColliePlugins`, `CHANGELOG.md` nem `docs/feature-map.md`
  (são da tarefa D1b, que roda em paralelo).
- Testes novos em `Tests/CollieDeviceTests/DeviceFrameTests.swift` (suíte `DeviceFrameTests`) com os casos do Aceite.
  O caso de `SimCtl.devices` lendo `deviceTypeIdentifier` vai em `SimTests`.
- Em `panel.open` do device, `state["frame"]` é gravado; falha ao ler o tipo vira `bare`, nunca erro.

Aceite: o do PRD (parte `DeviceFrameTests` e `SimCtl`). Regras do repo no rodapé do PRD.
