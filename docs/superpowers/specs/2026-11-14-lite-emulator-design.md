# Emulador Android leve (`collie-lite`) — design

Status: rascunho para aprovação. Nada implementado.

## Intenção e porquê

Dar ao Collie um AVD próprio, ultra leve, só com o necessário para instalar apps e rodar testes. Serve ao Collie (testes de agentes) e a Macs com pouco processamento (M1, 16 GB). O usuário vê e interage pelo painel de dispositivo que já existe (scrcpy); o agente usa a mesma via. O projeto é só o emulador consumir menos **RAM e CPU em uso** (prioridade dita pelo usuário; disco e tempo de boot são secundários).

## Estado atual (verificado)

- `Sources/CollieDaemonKit/Devices/Emulator.swift` sobe o emulador com `emulator -avd <nome>`, sem nenhuma flag, e declara-se somente leitura em `~/.android` e no SDK.
- AVDs do usuário: `Pixel_4_XL` (1440×3040, 2 GB, 7,5 GB em disco), `Pixel_9_Pro` (Play Store, 11 GB), `spike-net-api37` (1080×2400, 3 GB, 1,7 GB). Todos usam imagem `android-37.0` arm64.
- O SDK desta máquina não tem `cmdline-tools` (sem `avdmanager`/`sdkmanager`). O usuário vai instalar.
- Painel de dispositivo lista AVDs via `emulator -list-avds`, então um AVD novo aparece sozinho.

## Metas

- Um comando cria o AVD `collie-lite`, idempotente.
- `collie-lite` usa bem menos RAM e CPU do que `spike-net-api37` (o mais enxuto hoje), medido antes e depois.
- Funciona no painel de dispositivo e para o agente sem mudança neles.

## Não metas

- Imagem de sistema customizada ou AOSP (as imagens do emulador são Linux; não vale o custo).
- Mexer nos AVDs do usuário.
- Play Store, x86, iOS.
- Botão no painel para criar (fase 2).

## Anti-metas

- Escrever em `~/.android` ou no SDK sem o usuário pedir.
- Criar o AVD à mão quando o `avdmanager` não existe (falha com instrução).
- Ficar mais leve a ponto de o app de teste não rodar (sem Google Play Services é falha, não ganho).

## Abordagens consideradas

- **A. Só flags no lançamento.** Não escreve AVD, mas não baixa a resolução gravada no AVD nem o disco. Fica como complemento, não como base.
- **B. AVD `collie-lite` próprio (escolhida pelo usuário).**
- **C. Imagem customizada.** Descartada.
- Dentro de B: criar o AVD pelo `avdmanager` (escolhido, o usuário instala), escrever os arquivos à mão (descartado) ou baixar o `cmdline-tools` pelo Collie (descartado).

## Design

### Comando

`collie device lite create` (idempotente) e `collie device lite remove`. Roda no daemon; escreve só em `~/.android/avd/collie-lite*`.

### Localizar ferramentas

- `avdmanager`: `COLLIE_AVDMANAGER`, `$ANDROID_HOME`/`$ANDROID_SDK_ROOT` + `cmdline-tools/latest/bin/avdmanager`, depois `~/Library/Android/sdk/...`. Ausente: erro `unavailable` com o caminho do Android Studio para instalar.
- Java: `COLLIE_JAVA_HOME`, depois `/Applications/Android Studio.app/Contents/jbr/Contents/Home`, depois `/usr/libexec/java_home`. Passado como `JAVA_HOME` ao `avdmanager`.

### Escolha da imagem

Primeira instalada, nesta ordem: `google_apis` arm64-v8a de maior API; depois `google_apis_playstore*`. Nunca baixa imagem (sem `sdkmanager`). Nenhuma: erro dizendo qual instalar.

### Criação

1. `avdmanager create avd -n collie-lite -k "<pacote da imagem>" -d pixel --force` (flag `--force` só sobre o próprio `collie-lite`).
2. Sobrescrever chaves em `~/.android/avd/collie-lite.avd/config.ini` (mescla: troca ou acrescenta, mantém o resto):

| chave | valor | motivo |
|---|---|---|
| `hw.lcd.width` / `height` / `density` | 720 / 1280 / 320 | menos pixels para renderizar e codificar |
| `hw.ramSize` | 1536 | RAM menor |
| `hw.cpu.ncore` | 2 | CPU menor |
| `disk.dataPartition.size` | 2G | disco menor |
| `hw.camera.back` / `front` | none | sem câmera |
| `hw.audioInput` / `hw.audioOutput` | no | sem áudio |
| `hw.sensors.*` (orientation, proximity, humidity, pressure, magnetic_field, temperature) | no | menos sensores simulados |
| `showDeviceFrame` | no | sem moldura |
| `hw.gpu.mode` | a definir por medição (`auto` ou `host`) | ver abaixo |

   Estes valores são minha proposta; os números exatos saem da medição.

### Lançamento

Quando o AVD é `collie-lite`, `Emulator.launch` acrescenta `-no-audio -no-boot-anim -no-metrics`. Outros AVDs seguem sem flag. Essa é a única mudança em `Emulator.swift`.

### Medição

Antes de implementar, medir RSS e CPU ociosos (`ps` do processo `qemu-system-*`, 60 s após o boot) de `spike-net-api37`. Depois, medir `collie-lite` e o modo de GPU. Critério: `collie-lite` menor nos dois. A meta numérica sai da linha de base (não inventada aqui).

### Testes

Só funções puras, sem emulador real: localizar ferramentas, escolher imagem, argumentos do `avdmanager`, mesclagem de `config.ini`, flags extras do lançamento. Rodar por `--filter`.

## Decisões do usuário

- Foco em RAM e CPU em uso.
- Ver a tela e interagir já cobertos pelo painel existente.
- Abordagem B, com `avdmanager` instalado por ele.

## Minhas chamadas (conferir)

- Valores do AVD e flags acima.
- `create` idempotente; `remove` incluso.
- Sem botão no painel nesta fase.
- Preferência por `google_apis` sem Play Store.

## Fica para quem construir

- Modo de GPU final, depois da medição.
- Mensagens de erro exatas e formato da saída do comando.
- Onde fica o código novo (provável: `Sources/CollieDaemonKit/Devices/`).

## Resultado da medição (2026-11-14, M1 16 GB, Android 37 arm64)

Sistema acomodado (8 min depois do boot), painel fechado; carga = 160 swipes seguidos pelo `adb shell input`. O espelhamento
(scrcpy) não foi medido: o daemon isolado não tem o app. Uma rodada por linha.

| AVD | Pegada (`footprint`) | CPU em repouso | CPU sob swipes |
|---|---|---|---|
| `spike-net-api37` (3 GB, 1080×2400, GPU host) | 2,65 GB | ~8% | ~101% |
| `collie-lite`, GPU como o `avdmanager` grava (`hw.gpu.enabled=no`) | 2,5 GB | ~10% | ~385% |
| `collie-lite`, `hw.gpu.enabled=yes`, `hw.gpu.mode=host` (**adotado**) | **2,06 GB** | ~11% | **~36%** |

Achado: o `avdmanager` grava `hw.gpu.enabled=no`, o que faz o convidado renderizar por software; sem corrigir, o AVD "leve" fica
quase 4× mais caro em CPU que o `spike`. `LiteAvd.overrides` fixa `hw.gpu.enabled=yes` e `hw.gpu.mode=host`. O ganho de RAM é
menor que o corte do AVD sugere (~0,6 GB contra o `spike`), pelo custo fixo do emulador fora da RAM do convidado.
