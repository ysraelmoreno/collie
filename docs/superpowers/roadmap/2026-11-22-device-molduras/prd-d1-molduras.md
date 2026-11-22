# PRD D1: Painel de device com moldura por tipo de aparelho

Data: 2026-11-22. Design aprovado pelo dono: `docs/pages/painel-device-molduras/index.html` (direção C, oito
molduras; as alternativas A/B/C ficam em `docs/pages/painel-device/index.html`).

## Problema

O painel de device mostra o vídeo cru sobre um fundo afundado e, embaixo, três botões de texto (Voltar / Início /
Recentes) com uma linha de serial. Parece datado e não diz que aparelho está ali.

## Objetivo

O vídeo aparece dentro de uma moldura desenhada para o tipo de aparelho (telefone, dobrável, tablet, iPhone moderno,
iPhone com Início, iPad), escolhida sozinha. Os botões viram ícones em pílula, e o estado da conexão vai para o rodapé
com um ponto colorido.

## Não-objetivos

- Ações novas: só Voltar, Início, Recentes (Android) e Início, Bloquear (iOS), como hoje.
- Opção "Moldura: automática / nenhuma" no menu ⋯: o protocolo de painel não tem gancho de menu. Fica para depois;
  a moldura some sozinha quando falta espaço.
- Imagens ou marcas de fabricante: as molduras são formas genéricas.
- Moldura para aparelho Android físico: ele fica sem moldura.
- Botões laterais clicáveis (volume, energia): são só desenho.

## Fazer

### Parte 1: tipo de moldura (daemon, sem UI)

Arquivos: novo `Sources/CollieDevice/DeviceFrame.swift`; `Sources/CollieDevice/SimCtl.swift`;
`Sources/CollieDaemonKit/Devices/DeviceService.swift` e `DeviceService+Android.swift`;
`Sources/CollieDaemonKit/PanelCommands.swift`; `Tests/CollieDeviceTests/DeviceFrameTests.swift`.

1. **`DeviceFrame.Kind`** (enum `String`, `Codable`, `Sendable`): `phone`, `fold`, `tablet`, `island`, `classic`,
   `ipad`, `bare`. Funções puras:
   - `android(hwDeviceName: String?, emulator: Bool) -> Kind`: se não for emulador, `bare`. Se o nome tiver `fold`,
     `fold`. Se tiver `tablet` ou estiver na lista curta de tablets antigos (`pixel_c`, `nexus_9`, `nexus_10`),
     `tablet`. Qualquer outro valor, ou nenhum valor, dá `phone`.
   - `ios(deviceTypeIdentifier: String?) -> Kind`: se tiver `iPad`, `ipad`. Se tiver `iPhone-SE` ou for
     `iPhone-6`…`iPhone-8` (com ou sem `-Plus`), `classic`. Outro `iPhone-*` dá `island`. Desconhecido ou ausente dá
     `bare`.
2. **`SimDevice`** ganha `deviceType: String?`, lido de `deviceTypeIdentifier` no JSON do `simctl`. O `Codable`
   continua aceitando JSON antigo sem o campo.
3. **Android**: o nome do AVD de um emulador em execução já sai de `runningAvds` / `avds()`. Ler `hw.device.name` em
   `<ANDROID_AVD_HOME ou ~/.android/avd>/<nome>.avd/config.ini` (o mesmo caminho que `liteAvdDir` usa). Sem o arquivo
   ou sem a chave, passar `nil`. Um serial `avd:<nome>` já traz o nome.
4. **`resolveSerial`** passa a devolver também o `frame: DeviceFrame.Kind`. Em `panel.open` do device, gravar
   `state["frame"] = .string(kind.rawValue)` ao lado de `serial` e `platform`. Se ler o tipo falhar, o painel abre do
   mesmo jeito, com `bare`. Isso nunca vira erro.

### Parte 2: o painel (app)

Arquivos: `Sources/ColliePlugins/DevicePanel.swift`; novo `Sources/ColliePlugins/DeviceBezel.swift` (geometria pura e
o desenho); `Tests/ColliePluginsTests/DeviceBezelTests.swift`; `docs/feature-map.md`; `CHANGELOG.md` (uma linha em
"Unreleased › Changed", em inglês).

5. **Geometria** (`DeviceBezel.layout(kind:area:video:) -> (bezel: CGRect, screen: CGRect)`, pura): a tela da
   moldura tem **exatamente** a proporção do vídeo, então não sobra faixa preta. A moldura é a tela mais as bordas do
   tipo, centrada em `area` com 14 pt de folga. Bordas em pt, em retrato, conforme o protótipo: `phone` 6, cantos 32;
   `fold` 7, cantos 24; `tablet` 12, cantos 22; `island` 7, cantos 40; `classic` 6% nas laterais e 15% em cima e
   embaixo, cantos 34, tela com cantos 2; `ipad` 14, cantos 26; `bare` sem borda, tela com cantos 10. Com o vídeo
   em paisagem (largura maior que altura), as bordas giram: no `classic`, testa e queixo vão para as laterais.
   Os cantos da tela são os da moldura menos a borda. Se a tela ficar com menos de 200 pt de largura (ou de altura,
   em paisagem), o tipo vira `bare`.
6. **Toque**: o mapa de toque usa o `screen` da geometria no lugar de `videoArea`. `devicePoint` e `videoRect`
   recebem o retângulo da tela com a origem dele, e toque fora da tela (na borda ou no fundo) é ignorado. O arrasto
   que sai da tela continua preso à borda, como hoje. O `AVSampleBufferDisplayLayer` e a camada de imagem do iOS
   ocupam o `screen` com `cornerRadius` e `masksToBounds`.
7. **Desenho** (camadas, sem SwiftUI no caminho do vídeo): o corpo da moldura num quase preto fixo (`#0B0C0F`, com
   contorno `#2A2D35`) e sombra. A cor é fixa de propósito: aparelho é escuro nos dois temas. O fundo do palco usa
   as cores do tema (`CollieColor`), com o degradê do protótipo, e se redesenha em `viewDidChangeEffectiveAppearance`,
   como `applyChrome` faz hoje. Recortes **sobre** o vídeo: furo da câmera (`phone`), ilha (`island`), dobra
   translúcida (`fold`). Na borda: câmera (`tablet`, `ipad`); alto-falante, câmera e botão Início redondo
   (`classic`). Botões laterais nas posições do protótipo. Na rotação, tudo gira junto, como os recortes do
   protótipo.
8. **Botão Início do `classic`**: é clicável (o mesmo `home()` da pílula) e tem rótulo de acessibilidade "Início".
   Nenhuma outra parte da borda recebe clique.
9. **Rodapé** (`DeviceFooter`): uma linha de ícones em pílula, centrada (SF Symbols `chevron.left`, `circle`,
   `square`; iOS `circle`, `lock`), 44 × 32, com `help` e rótulo de acessibilidade iguais aos títulos de hoje. Abaixo,
   em monoespaçada, o ponto de estado com "ao vivo", "conectando" ou "offline" à esquerda e o transporte
   (`adb`/`simctl`) à direita. O serial já aparece no cabeçalho do painel. `footerHeight` continua sendo uma
   constante (agora ~72); o mapa de toque não pode depender de métrica de fonte. Desconectado: ícones em 40% e
   desligados.
10. **Estado**: o ponto acompanha `status`. "Conectando…" fica amarelo e pulsando (sem pulso com "reduzir
    movimento"), "streaming" fica verde e o resto fica cinza. A camada de estado com **Reconectar** cobre só o
    `screen`, com fundo desfocado.
11. **Painel antigo** sem `state["frame"]`: `bare`. Não migrar nada.
12. `docs/feature-map.md`: atualizar a entrada do painel de device (moldura automática, de onde vem o tipo, como
    verificar).

## Aceite

`DeviceFrameTests`: `pixel_8` dá `phone`, `pixel_fold` dá `fold`, `pixel_tablet` e `medium_tablet` dão `tablet`,
`nil` em emulador dá `phone`, não emulador dá `bare`. iOS: `…SimDeviceType.iPad-Air-13-inch-M2` dá `ipad`,
`…iPhone-SE-3rd-generation` dá `classic`, `…iPhone-8-Plus` dá `classic`, `…iPhone-16-Pro` dá `island`, `nil` dá
`bare`. `SimCtl.devices` lê `deviceTypeIdentifier`, e JSON sem ele dá `nil`.

`DeviceBezelTests`: para cada tipo, a proporção de `screen` é igual à do vídeo (±0,5 pt) e `screen` fica dentro de
`bezel`, que fica dentro de `area`. Vídeo em paisagem gira as bordas do `classic`. Área pequena (tela < 200 pt) dá
`bare`. `devicePoint` com o novo retângulo: o centro da tela vai ao centro do vídeo, um ponto na borda dá `nil` e os
cantos da tela vão aos cantos do vídeo.

**No app real** (o dono confere; registrar aqui): emulador Pixel (telefone), Pixel Fold, Pixel Tablet, iPhone 16 Pro,
iPhone SE e iPad, nos temas claro e escuro; rotação de um telefone; toque e arrasto acertando o lugar em cada
moldura; botão Início do SE; painel encolhido até a moldura sumir; desconectar e reconectar.

## Check

```
swift test --disable-sandbox --filter DeviceFrameTests && swift test --disable-sandbox --filter DeviceBezelTests
```

Rodar também as suítes já existentes que cobrem `devicePoint`/`videoRect` e `SimCtl` (achar com
`grep -rln "devicePoint\|SimCtl.devices" Tests`), cada uma com `--filter`.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`, `asyncAfter`, `try!` ou `@unchecked Sendable` novos. Textos que o dono vê em português; o
CHANGELOG em inglês. Commit com mensagem convencional, só dos seus arquivos; nada de push.
