# Device: helper residente de acessibilidade (Android)

Data: 2026-11-22 · Estado: proposta com POC medida. Complementa `2026-11-22-device-screen-find-design.md` (S4, passo 2).

## Problema e medição

`device ui|screen|find|wait` custam ~2.050 ms por leitura da tela: é o `uiautomator dump` (a espera de idle e a partida
do processo), não o adb (29 ms), o parse (1 ms) nem o screencap (140 a 190 ms). `--compressed` e `/dev/tty` não mudam.
Cada passo do agente paga isso, e `find --scroll` multiplica por volta. O toque por `input tap` também abre um
processo por toque.

POC feita em 2026-11-22 (emulador API 37, tela Offers do BEES), código em `poc/` desta spec:

| Medida | uiautomator | Helper (serviço de acessibilidade) |
|---|---|---|
| Leitura da tela | ~2.050 ms | 4 a 120 ms em regime; 523 a 650 ms na 1ª chamada; 1,58 s numa leitura logo após trocar de tela |
| Tap | `input tap` (processo por toque) | 11 ms (`dispatchGesture`) |
| Conteúdo | 55 nós | 55 nós, mesmos textos e ids (`configuration_fab` incluso) |

Descartadas na POC: OCR (Vision 540 a 1.625 ms, tesseract 2.061 ms, não vê ícone sem texto) e helper via
`app_process` com `UiAutomation` (SIGKILL no `connect()`, mesmo como uid shell; causa não investigada).

## Objetivo

Um app auxiliar pequeno, instalado no emulador ou aparelho, que roda como serviço de acessibilidade e responde ao daemon
com a árvore da tela, toques, gestos e ações semânticas em dezenas de milissegundos, para qualquer app que exponha
acessibilidade. As respostas dos comandos `collie device` não mudam de forma; só ficam rápidas e ganham ações melhores.

## Fora de escopo

iOS (medir o AXe antes; a ideia equivalente seria um runner XCTest residente, outra spec). OCR e visão para apps sem
árvore (jogo, canvas, Compose sem semântica): fica como fallback futuro. Qualquer coisa que exija root.

## Desenho

### H1. O helper (`Helpers/android-device/`)

- Pacote `com.collie.helper`, minSdk 26, um `AccessibilityService` (`HelperService`) com `canRetrieveWindowContent`,
  `canPerformGestures`, `flagIncludeNotImportantViews`, `flagReportViewIds`, `flagRetrieveInteractiveWindows`.
- Escuta num **socket abstrato** (`LocalServerSocket("collie-helper")`), não em TCP: a POC usou `127.0.0.1:7788`, e
  qualquer app do aparelho poderia conectar e ler a tela. O helper aceita só conexões cujo `getPeerCredentials().uid`
  seja shell (2000) ou root (0): o que chega pelo `adb forward localabstract:collie-helper`.
- Protocolo de linhas (um pedido por linha, resposta de uma linha JSON, `id` ecoado):
  - `{"op":"hello"}` → `{version, sdk, display:{w,h}}`
  - `{"op":"dump"}` → árvore: nós com `text, desc, id, class, bounds, clickable, selected, checked, enabled, focused,
    scrollable, password` e o caminho `path` (índices dos filhos) para endereçar o nó depois
  - `{"op":"tap","x":..,"y":..}` e `{"op":"swipe","x1":..,"y1":..,"x2":..,"y2":..,"ms":..}` por `dispatchGesture`
  - `{"op":"click","path":[..]}` usa `ACTION_CLICK` no nó (sobe ao ancestral clicável); cai no toque no centro
  - `{"op":"text","value":".."}` por `ACTION_SET_TEXT` no nó focado; `{"op":"scroll","path":[..],"dir":"fwd|back"}`
  - `{"op":"global","action":"back|home|recents|notifications"}`
  - `{"op":"subscribe"}` empurra `{"ev":"window"|"content","t":..}` com debounce de 100 ms (base do `wait --stable`)
- Texto de campo com `isPassword` volta mascarado (`"•••"`), nunca o valor.
- Sem permissão de INTERNET: o socket é local. (A POC precisou de INTERNET só por usar TCP.)
- Build sem Gradle, como na POC: `aapt2 compile/link`, `javac`, `d8`, `zipalign`, `apksigner`, com chave debug fixa do
  repositório. `scripts/build-device-helper.sh` acha o último `build-tools` do SDK e o JDK (`JAVA_HOME` ou o JBR do
  Android Studio; o Mac não tem JRE do sistema). O **APK pronto (~6 KB) vai commitado** em `Resources/collie-helper.apk`,
  com teste que confere a versão; o CI não precisa do SDK.

### H2. Ciclo de vida no daemon (`CollieDaemonKit/Devices/DeviceHelper*.swift`)

- Novo `DeviceHelper` por dispositivo: instala (`adb install -r`), habilita (acrescenta ao valor existente de
  `enabled_accessibility_services`, nunca sobrescreve; `accessibility_enabled 1`), abre `adb forward tcp:<livre>
  localabstract:collie-helper`, faz `hello` e confere `version`; versão antiga → reinstala.
- Quando: emulador, na primeira ação `device` do painel (descartável, sem pedir). Aparelho físico só com opt-in
  explícito: `collie device helper install --serial <id>` (o serviço de acessibilidade lê todo o conteúdo da tela
  enquanto estiver ligado, e alguns fabricantes bloqueiam `settings put secure`).
- `collie device helper status|install|remove` (remove: tira da lista de serviços, desinstala, remove o forward).
- Ao fechar o último painel do dispositivo o daemon fecha o forward; o serviço pode ficar habilitado (custo ~0), a menos
  que o usuário peça `remove`.
- Falha em qualquer etapa (sem `settings`, OEM bloqueia, helper não responde em 3 s): **cai no `uiautomator` de hoje**,
  uma vez por sessão do painel, e o `status` diz por quê. Nenhum comando `device` falha por causa do helper.

### H3. Comandos `device` pelo helper

`device ui|screen|find|wait|tap|swipe|text|key` usam o helper quando ele está pronto, com as mesmas respostas de
hoje. Diferenças que o agente percebe:
- `tap --text|--id|--ref` usa `click <path>` (semântico) e só cai no toque por coordenada se o nó não aceitar clique.
- `swipe` por `dispatchGesture` (sem processo por gesto).
- `--timing` passa a mostrar `source: "helper"|"uiautomator"` e o tempo de cada etapa.
- `device screen` ganha os estados que hoje faltam (`selected`, `checked`, `enabled`, `scrollable`).

### H4. Espera por eventos

`wait --stable` e `--settle stable` deixam de fazer polling de árvore: o daemon assina `subscribe` e considera a tela
estável quando não chega evento por N ms (padrão 300). Sem helper, o comportamento de hoje.

## Arquivos

- Novo: `Helpers/android-device/` (fonte Java, manifesto, recursos), `scripts/build-device-helper.sh`,
  `Resources/collie-helper.apk`, `Sources/CollieDevice/HelperProtocol.swift` (codificação, puro),
  `Sources/CollieDaemonKit/Devices/DeviceHelper.swift`.
- Alterados: `DeviceService.swift` e `+Android.swift` (escolher fonte), `Plugins.swift` (`device.helper`),
  `scripts/bundle-app.sh` (copiar o APK para `Resources/`), `docs/referencia.md`, `docs/feature-map.md`,
  `CollieOrientation.swift` (uma frase, teto 1500).

## Tarefas para o laço

| # | Tarefa | Depende de |
|---|---|---|
| H1 | Fonte do helper, `build-device-helper.sh`, APK commitado e `HelperProtocol.swift` com testes | nenhuma |
| H2 | `DeviceHelper` (instala, habilita sem sobrescrever, forward, hello, versão) e `collie device helper`, com fallback e testes com adb e socket falsos | H1 |
| H3 | `ui|screen|find|tap|swipe|text|key` pelo helper com as mesmas respostas, `--timing source`, estados novos | H2 |
| H4 | `wait --stable` por eventos | H3 |
| H5 | docs, orientação e `bundle-app.sh` | H4 |

Todas tocam os mesmos arquivos: sequenciais, sem scope (o cartão tem teto de 1500 caracteres). H1 e H2 já são tarefas
grandes: se alguma falhar três vezes sem commit, dividir (a E3 mostrou que o tamanho é a causa).

## Testes

- Sem aparelho: codificação do protocolo, escolha de fonte (helper ou fallback), `enabled_accessibility_services`
  acrescentado sem apagar os outros, versão antiga reinstala, helper que não responde cai no `uiautomator`.
- `HelperServer` falso em teste (socket Unix) que responde `hello`/`dump`/`tap` do jeito da POC.
- Manual no emulador (critérios abaixo): o laço usa o daemon instalado e não alcança o aparelho.

## Critérios de aceite (no emulador, com o bundle instalado)

1. `collie device helper install` instala e habilita; `status` mostra `ready`, versão e `source: helper`.
2. `device ui --timing` em regime estável: mediana < 150 ms (hoje ~2.050 ms), 1ª leitura < 1 s.
3. `tap --text "Combos" --then screen` conclui em < 400 ms no total, fora a espera do app.
4. Habilitar o helper com outro serviço de acessibilidade ativo preserva o outro (checar `enabled_accessibility_services`).
5. Desinstalar o helper, ou bloquear `settings put secure`, faz os comandos continuarem funcionando pelo `uiautomator`.
6. Repetir o teste do Cursor (fechar o BEES, abrir, "Continue to App → + → Open Deals"): tempo total bem abaixo dos
   135 s da rodada anterior (passos de ~5-6 s hoje).

## Riscos

- **Privacidade e superfície:** um serviço de acessibilidade lê toda a tela. Mitigações: socket abstrato com checagem de
  uid, senha mascarada, aparelho físico só com opt-in explícito, `remove` documentado, nada sai do aparelho.
- **Fabricantes:** alguns (MIUI, ColorOS) bloqueiam `settings put secure` ou matam serviços em segundo plano; o
  fallback cobre, e o `status` explica. Só foi testado em emulador API 37.
- **Latência da primeira leitura** (523 a 650 ms) e de leituras logo após transição (1,58 s numa medida): medir em mais
  telas antes de prometer o número no critério 2.
- **Conflito com outro serviço de acessibilidade** (TalkBack, outro automatizador): a lista é acrescentada, mas dois
  serviços com `canRetrieveWindowContent` podem competir em alguns aparelhos.
- **Apps sem árvore** (jogos, canvas, Compose sem semântica) continuam sem tela útil: fica a porta do OCR.
- A chave de assinatura debug fixa é pública no repositório: serve só para este helper de desenvolvimento; trocar por
  uma chave própria antes de distribuir para usuários finais.
