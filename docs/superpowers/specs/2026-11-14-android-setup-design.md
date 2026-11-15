# Instalação do Android pelas Preferências — design

Status: rascunho para aprovação. Nada implementado. Continua o `2026-11-14-lite-emulator-design.md`.

## Intenção e porquê

Quem não tem o Android Studio não consegue usar o painel de dispositivo nem o `collie-lite`: falta `emulator`, `adb`, `avdmanager` e uma imagem de sistema, e o Collie hoje só manda instalar pelo Android Studio (`Emulator.missing`). Uma tela **Android** nas Preferências vê o que falta e instala com um botão, mostrando as licenças do Google para o usuário aceitar. Serve a quem testa com o Collie e a Macs fracos (M1), onde instalar o Studio inteiro é pesado.

## Estado atual (verificado)

- O Collie traz só o `scrcpy-server`; o resto vem do SDK que o usuário instalou. Procura o `emulator` em `COLLIE_EMULATOR`, `ANDROID_HOME`/`ANDROID_SDK_ROOT` e `~/Library/Android/sdk` (`Emulator.locate`); o `avdmanager` em `COLLIE_AVDMANAGER` e nos mesmos SDKs (`AvdManager.locate`), com Java do `COLLIE_JAVA_HOME`, do Android Studio (`.../jbr`) ou de `/usr/libexec/java_home`.
- As Preferências (`PreferencesView.swift`) são uma janela com seletor segmentado: Aparência, Plug-ins, Celular. O daemon já baixa coisas (`font.add` busca fontes). O desenho da nova janela está em exploração numa Prévia do Product Manager; esta spec fixa só o contrato de dados e o comportamento, não o layout.
- O comando `device.lite.create` (já na `main`) cria o `collie-lite` pelo `avdmanager`.

## Metas

- Uma tela **Android** mostra, por item, se existe e de onde vem: Java, Command-line Tools, Emulator, Platform-tools, imagem de sistema.
- Um botão instala só o que falta, depois de o usuário aceitar as licenças.
- Reaproveita o SDK do Android Studio quando existe; só cria um SDK próprio quando não há nenhum.
- Progresso por item, cancelar, tentar de novo, e no fim **Criar emulador leve**.
- Os mesmos recursos como comandos para agentes e testes: `collie android status` e `collie android install`.

## Não metas

- Empacotar o emulador, o JDK ou o SDK dentro do `Collie.app`.
- Desinstalar componentes do SDK (o usuário apaga a pasta; só `device.lite.remove` existe).
- Intel/x86_64 na v1: o erro diz que só Apple Silicon é suportado. (Minha chamada.)
- Retomar download interrompido, escolher versão de API, instalar mais de uma imagem.
- Versão Windows/Linux.

## Anti-metas

- Baixar ou escrever algo sem o usuário clicar em Instalar.
- Aceitar licenças pelo usuário.
- Nos downloads do próprio Collie (JDK e `cmdline-tools`): baixar de outro host que não os da lista, ou usar arquivo sem checksum conferido.
- Mexer no SDK do Android Studio além de instalar os itens que faltam.

## Abordagens consideradas

- **A. Rodar as ferramentas do Google (escolhida pelo usuário):** baixar o `cmdline-tools` e rodar o `sdkmanager`; Java do sistema ou de um JDK baixado.
- **B. O Collie baixa os pacotes pelo catálogo XML:** reimplementa o `sdkmanager`; frágil, e exigiria escrever AVD à mão. Descartada.
- **C. Só guiar o usuário até o Android Studio:** barato, mas não instala. Descartada.
- **Decisão do usuário:** reaproveitar o SDK do Studio quando houver.

## Design

### Onde fica o SDK

`AndroidSdk.resolve(env:home:colliePath:) -> URL`, na ordem: `COLLIE_ANDROID_SDK` (também usado nos testes e testes manuais), `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`, e por fim `~/Library/Application Support/Collie/android-sdk`. Vale o primeiro diretório que **parece um SDK** (contém `platform-tools`, `emulator`, `cmdline-tools` ou `system-images`; um `ANDROID_HOME` vazio ou velho é pulado); se nenhum existir, vale o do Collie e o install o cria. Todos os localizadores (`Emulator.locate`, `AvdManager.locate`, o do `adb`) passam a usar esta função. Instalar nunca troca de SDK no meio.

### Java

Ordem: `COLLIE_JAVA_HOME`; o JDK do Android Studio; `/usr/libexec/java_home` com versão 17 ou maior; um JDK próprio em `~/Library/Application Support/Collie/jdk`, baixado (Temurin, build aarch64 de macOS, 17 ou maior conforme o que o `cmdline-tools` baixado exigir; o builder confere). O JDK baixado é descompactado sem executar nada antes do checksum.

### Itens e o que cada um faz

| item | pronto quando | instalação |
|---|---|---|
| Java | um JDK da lista acima responde `-version` | baixar o JDK próprio |
| Command-line Tools | `<sdk>/cmdline-tools/latest/bin/sdkmanager` executável | baixar o zip do Google (`dl.google.com`) e colocar em `cmdline-tools/latest` |
| Platform-tools | `<sdk>/platform-tools/adb` | `sdkmanager "platform-tools"` |
| Emulator | `<sdk>/emulator/emulator` | `sdkmanager "emulator"` |
| Imagem | alguma `system-images/*/google_apis*/arm64-v8a` | `sdkmanager "system-images;android-N;google_apis;arm64-v8a"`, com N a maior API que não seja prévia |

A ordem de instalação é a da tabela. Um item só é instalado se faltar.

### Licenças

`android.licenses` devolve os textos que o `sdkmanager` pede e um id estável por licença (o hash que ele grava em `<sdk>/licenses/`). O aceite é explícito: `android.install` só roda com os ids aceitos, e grava o aceite do mesmo modo que o `sdkmanager --licenses` (o builder confere o formato exato). A licença do JDK próprio (GPLv2 com exceção de classpath) aparece como informação, sem aceite. Os textos das licenças só existem depois que o `sdkmanager` roda, então a instalação tem duas fases: **(1) Preparar** (JDK próprio, se faltar, e `cmdline-tools`; poucas centenas de MB, sem licença do SDK) começa no clique em Instalar; **(2) Instalar** (`platform-tools`, `emulator`, imagem; o grosso do download) só começa depois do aceite das licenças. Se o usuário recusar, a fase 2 não roda e nada do SDK é baixado além do que a fase 1 trouxe. O estado `status` distingue `needsLicense`.

### Comandos (daemon, só admin)

- `android.status` → `{sdk: {path, source}, items: [{id, state: ok|missing|installing, detail}], lite: bool}`.
- `android.licenses` → `[{id, title, text, accepted}]`.
- `android.install --accept <ids>` → começa um trabalho e devolve `{job}`; um só por vez (outro pedido: erro `busy`).
- `android.cancel` → termina o processo em curso, apaga o parcial.
- Eventos `android.progress`: `{job, item, percent, bytes, total}`, `android.done`, `android.failed {item, message}`.
- Todos admin: baixam centenas de MB e escrevem fora do sandbox do agente. Agentes só leem `device.list` e usam o resultado.

### Execução

Download com `URLSession`, só HTTPS, só dos hosts `dl.google.com`, `api.adoptium.net` e o redirecionamento deste para `github.com/adoptium`, com SHA-256 conferido (do catálogo do Google; do JSON da API do Adoptium). Espaço livre conferido antes (imagem >1 GB). `sdkmanager` roda via `BoundedProcess`, em grupo de processos próprio (cancelar mata o grupo), com `JAVA_HOME` e `--sdk_root`; o progresso vem da saída dele. Falha parcial: mostra o item e deixa **Tentar de novo**, que só refaz o que ainda falta.

### Tela

Segue a opção de layout que o usuário escolher na Prévia. Conteúdo fixo: linhas de status por item com origem; tamanho a baixar; licenças com aceite; barra por item; Cancelar; erro com Tentar de novo; **Criar emulador leve** e **Remover** (`device.lite.*`); SDK em uso com "Mostrar na pasta".

### Testes

Funções puras: ordem de `AndroidSdk.resolve`, escolha de Java, escolha da imagem (maior API sem prévia), parse do progresso do `sdkmanager`, parse dos textos de licença, checagem de espaço. Daemon com `sdkmanager` falso (script) e um downloader injetável (protocolo), sem rede nem SDK real. Teste manual de ponta a ponta numa pasta temporária por `COLLIE_ANDROID_SDK`, sem tocar o SDK do Studio; rodar por `--filter`.

## Esclarecimentos (da checagem do construtor; todos chamadas minhas)

- **SDK parcial do Studio:** instalar nele os itens que faltam é o que o Studio faria e é o que o usuário escolheu ao reaproveitar. `cmdline-tools` conta como pronto se existir `cmdline-tools/latest` **ou** qualquer `cmdline-tools/<versão>` com `bin/sdkmanager` (preferindo `latest`); se só houver versão numerada, usa-a em vez de criar `latest`.
- **Consentimento da fase 1:** o botão Instalar fica ao lado de um aviso fixo, visível antes do clique: "baixa o Command-line Tools do Google (termos do Android SDK) e, se preciso, o JDK Temurin". O clique vale como consentimento só para a fase 1; a fase 2 continua exigindo o aceite explícito das licenças do SDK.
- **Licenças:** `android.licenses` antes de existir `cmdline-tools` devolve o erro `notReady` (o `status` mostra `needsPrepare`). O id é o hash que o próprio `sdkmanager` grava em `<sdk>/licenses/`. Licenças já aceitas (SDK do Studio) vêm com `accepted: true` e o passo de aceite some se todas estiverem aceitas.
- **Imagem:** a fonte da verdade é `sdkmanager --list` (maior API estável com `google_apis;arm64-v8a`; se não houver arm64 nessa API, desce para a anterior). "Pronta" aceita qualquer `google_apis*` arm64 já instalada, mesmo antiga: o `device.lite.create` já escolhe sozinho entre as instaladas (`LiteAvd.pickImage`), então nada é passado a ele.
- **Java:** o `cmdline-tools` é só um zip e baixa-se antes de qualquer Java. O JDK do sistema vale se for 17 ou maior; se o `sdkmanager` falhar por versão de classe, baixa-se o JDK 21 (Temurin LTS). O JDK próprio é baixado pelo `URLSession` (sem atributo de quarentena); o construtor confere se o macOS o executa sem bloqueio.
- **Hosts:** a lista de hosts e o SHA-256 valem para o que **o Collie** baixa (JDK e zip do `cmdline-tools`). O que o `sdkmanager` baixa na fase 2 usa a pilha e os checksums do próprio Google; o Collie confia nele e não afirma controlar esses downloads. Redirecionamentos só para hosts da lista (`dl.google.com`, `api.adoptium.net`, `github.com/adoptium`, `objects.githubusercontent.com` para o asset).
- **CLI:** `collie android status` e `collie android install --accept <ids>` chamam os comandos do daemon; sem `--accept-all`, e só admin (o terminal do agente não tem esse poder). O `install` imprime uma linha por evento de progresso até o fim.
- **Concorrência:** se houver outro `sdkmanager` ou o Android Studio rodando no mesmo SDK (processo `sdkmanager` ou o lock do Studio), o install recusa com `busy`. Os downloads e a extração vão para uma pasta de staging `<sdk>/.collie-staging/` e só então são movidos; cancelar apaga só o staging do trabalho, nunca o `cmdline-tools` que já existia. O estado do trabalho não é gravado: ao subir, o daemon limpa um staging órfão e `busy` não persiste.
- **Espaço e tamanho:** o catálogo XML traz o tamanho de cada arquivo; a tela mostra a soma do que vai baixar (com estimativa fixa se o catálogo falhar) e a checagem exige 2× essa soma livres no volume do SDK.

## Decisões do usuário

- Opção A (ferramentas do Google).
- Reaproveitar o SDK do Android Studio.
- Tela de Preferências com 3 propostas de layout, em Prévia.

## Minhas chamadas (conferir)

- Apple Silicon apenas; sem desinstalar; sem retomar download.
- Todos os comandos admin; um trabalho por vez.
- Ordem de busca do SDK e do Java acima; `COLLIE_ANDROID_SDK` como sobrescrita.
- A maior API sem prévia como imagem padrão.

## Fica para quem construir

- URL exata e checksum do `cmdline-tools` mais novo (catálogo `repository2-*.xml`) e versão mínima do Java dele.
- Formato exato do aceite em `<sdk>/licenses/` e como capturar os textos do `sdkmanager`.
- Como ler o progresso do `sdkmanager` (a saída muda entre versões).
- Nomes dos eventos, formato dos erros e onde mora o código (provável: `Sources/CollieDaemonKit/Android/`).

## Resultado do E2E (2026-11-14, daemon isolado, SDK e AVD home temporários)

Fluxo `android status` → `install` (fase 1) → `licenses` → `install --accept …` (fase 2) → `device lite create` terminou em `ready` e `device.list` mostrou `avd:collie-lite`; fase 2 levou ~2 min. O `collie-lite` do usuário em `~/.android/avd` não foi tocado.

Mudanças em relação ao desenho, todas no código:
- **`cmdline-tools` padrão ≤ 20.0** (`AndroidSdk.maxCmdlineTools`). Motivo: o 23.0 (o `latest` do catálogo) é um invólucro do novo CLI `android` que grava `licenses/android-sdk-license` sozinho, sem perguntar, ignora `--licenses` ("no longer needed") e escreve fora do SDK (`$HOME/.android/bin/android-cli`, `$HOME/.android/cli`). O "Illegal entry path" visto no primeiro E2E não é a causa (ver "Decisão do dono").
- **Checksum do catálogo do Google é SHA-1** (não há SHA-256 no `repository2-3.xml`); usa SHA-256 quando existir. O Temurin usa SHA-256 do JSON do Adoptium.
- **Host a mais:** `release-assets.githubusercontent.com` (para onde o GitHub redireciona os assets do Adoptium hoje), além de `objects.githubusercontent.com`.
- **Android Studio só bloqueia o SDK dele** (`~/Library/Android/sdk`), como diz "no mesmo SDK"; outro `sdkmanager` bloqueia sempre.
- **`COLLIE_JAVA_HOME` definido e vazio** = só o JDK do Collie (para testes e E2E).
- **Java:** `/usr/libexec/java_home -v 17+`.

Formatos reais conferidos:
- Licenças: `--licenses` mostra cada uma com cabeçalho `N/M: License <id>:` e `Accept? (y/N):`; o aceite é `<sdk>/licenses/<id>` com o SHA-1 do texto (ex.: `android-sdk-license` = `24333f8a…`). O hash calculado pelo Collie foi aceito pelo `sdkmanager`.
- Progresso: linhas `[===   ] N% …` com `\r`; o parser lê a última.
- `--licenses` lista **todas** as 8 licenças pendentes do repositório (TV, XR, MIPS, preview…), não só as dos 3 pacotes; o install exige todas. Resolvido: o Collie pede só as que os pacotes usam (ver "Decisão do dono").

Limites vistos:
- O JDK próprio baixou (199,7 MB), conferiu e extraiu, mas mover para `~/Library/Application Support/Collie/jdk` deu EPERM a partir do terminal: o macOS protege a pasta de dados do app instalado. O `collied` de dentro do `Collie.app` é dono dela; o E2E seguiu com o JDK do Studio. O staging foi limpo na falha.
- O `sdkmanager` 20 regrava o cache de catálogo em `~/.android/cache` (arquivos que já existiam), ignorando `ANDROID_USER_HOME`.
- ~~Baixar o JDK quando o `sdkmanager` falha por versão de classe~~: feito (ver "Decisão do dono", JDK antigo).
- ~~`cmdline-tools` 21+ nunca roda~~ (regra do `fa95272`): substituída pela "Decisão do dono" abaixo.

## Decisão do dono (2026-11-14, Task 7)

- **Aceite.** O clique em **Instalar**, com o aviso visível "Ao instalar, você aceita os termos do Android SDK" e link para o texto do Google (https://developer.android.com/studio/terms), é o aceite. Com o 23.0 não há lista de licenças por pacote: ele grava o aceite sozinho. Com o clássico, o Collie continua gravando só as licenças mostradas.
- **Licenças do clássico: só as necessárias.** O Collie busca no `dl.google.com` (fetch do `prepare`, limite de 16 MiB) o `repository2-3.xml` e o `sys-img/google_apis/sys-img2-3.xml` e lê o `uses-license` dos pacotes canal 0 que faltam (`platform-tools`, `emulator` → `android-sdk-license`; imagem google_apis arm64-v8a → `android-sdk-arm-dbt-license`). Mostra e exige só pendentes ∩ necessárias; grava só os ids que o usuário passou **e** que estão nesse conjunto. Catálogo indisponível ou ilegível: exige todas as pendentes (regra anterior), e continua gravando só ids passados pelo usuário.
- **Versões do `cmdline-tools`.** Padrão: o clássico mais novo ≤ 20.0 (é o que o Collie baixa). O 23.0 é **permitido** (ex.: o `latest` do Studio). Versão desconhecida (21, 22, > 23) passa por uma **sondagem**: instala `platform-tools` (~15 MB) num SDK temporário vazio, com HOME e `ANDROID_USER_HOME` temporários e stdin fechado; se criar `licenses/` sem aceite, bloqueia com mensagem clara; senão é tratada como clássica (resultado guardado por versão, nunca de uma execução cancelada ou morta). O `--list` não serve: nem o 23.0 grava licença nele. `23.0.x` conta como 23.0.
- **Isolamento.** Todo `sdkmanager` roda com `HOME` temporário e `ANDROID_USER_HOME=<HOME>/.android` (layout padrão; o 23.0 grava `bin/android-cli` e `cli/` direto no `ANDROID_USER_HOME`) (por trabalho, apagados no fim) e `--sdk_root=<sdk>` explícito, para nada ir parar em `~/.android` (o 20.0 regrava `~/.android/cache`; o 23.0 instala `~/.android/bin/android-cli`).
- **Downloads do Collie.** Hosts: `dl.google.com`, `api.adoptium.net`, `github.com/adoptium/…`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`; só HTTPS, porta padrão, sem credenciais. Checksum: SHA-256 quando o catálogo tem; senão o SHA-1 do catálogo do Google (o `repository2-3.xml` só traz SHA-1); Temurin com o SHA-256 do Adoptium.
- **"Illegal entry path" (1º E2E):** reproduzido. Só aparece com `--sdk_root` contendo `..` (era o caminho do meu E2E), no 23.0; o 20.0 não liga. Era ambiente. O Collie agora passa o `--sdk_root` normalizado.
- **JDK antigo (clássico).** Saídas reais do 20.0 com Temurin 11: `This tool requires JDK 17 or later…` (checagem do script) ou, com `SKIP_JDK_VERSION_CHECK`, `UnsupportedClassVersionError` (`AndroidSdk.needsNewerJava` reconhece as duas). Quando um `sdkmanager` clássico (`--licenses`, `--list`, instalação) falha assim e o Java usado não é o JDK do Collie: baixa o Temurin (mesmo caminho do `prepare`: `api.adoptium.net`, SHA-256, staging) e repete aquela chamada **uma vez** com o JDK do Collie; dali em diante o instalador usa esse JDK (até o daemon reiniciar). A escolha do Java (instalador e `avdmanager`) pula um JDK cujo `release` diz `JAVA_VERSION` < 17 (sem `release`: aceito); assim, um Java antigo identificável nem é usado e o `prepare` baixa o do Collie. Falhar assim de novo é erro; nunca há laço. O 23.0 traz o próprio Java: não se aplica.
- **Cache do CLI do 23.0.** O que o lançador do 23.0 baixa no HOME temporário (`.android/bin/android-cli`, ~72 MB, e `.android/cli/bundles/`, ~255 MB; sem `lock`, analytics, tos) fica em `<raiz do daemon>/cache/android-cli/<revisão-tamanho-mtime do bin/android>/` e é copiado (clone APFS) para o HOME de cada trabalho: são os mesmos arquivos que a ferramenta do Google gerou, numa pasta só do Collie (0700, gravada por cópia + rename atômico, só após uma execução bem-sucedida), nunca em `~/.android` nem no SDK.
