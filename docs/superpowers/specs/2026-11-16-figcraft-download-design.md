# Motor de design (figcraft) baixável — design

Status: aprovado pelo dono (2026-11-16), revisado (revisão independente aplicada em 2026-11-16; dois pontos
**pendentes do dono**, ver seção própria). Nada implementado. Plano: `docs/superpowers/plans/2026-11-16-figcraft-download.md`.

Unidades: tamanhos em MB decimais (1 MB = 10⁶ bytes), como mostra o `ByteCountFormatter` (`.file`) na UI. Os números
de `du` (MiB) foram convertidos.

## Intenção e porquê

O figcraft (motor do painel Design e dos comandos `collie design *`) ocupa 114 MB dos 216 MB do `Collie.app` e é o
passo mais lento do CI de release (Rust → wasm, 20 a 40 min a frio). Quem não usa design paga o download e o CI paga o
tempo a cada release do app, mesmo quando o figcraft não mudou. O dono quer o dmg do Collie **sem** o figcraft e o
motor como download separado, sob pedido, em Preferências (baixar com progresso, remover e atualizar). O motor é
compilado e publicado por um workflow próprio, só quando o pin do figcraft muda.

## Estado atual (verificado no código)

- **Build**: `scripts/build-figcraft.sh` fixa figcraft `v0.7.0` (commit `47438dd4a2e8b49a7e6bb3dfd480262dadc37f12`),
  craft-fonts `43913056…`, Rust 1.99.1, trunk 0.22.0, wasm-bindgen 0.2.129, binaryen 131 (sha256 conferido), aplica
  `patches/figcraft/0001…0005` e gera `vendor/figcraft/{bin,web,licenses}`; o fonte e o `target/` do cargo ficam em
  `vendor/figcraft-src` (`build-figcraft.sh:17,83`). Medido: `bin/` 91 MB (`figcraft-cli` 80 MB, `figcraft-server`
  11 MB), `web/` 23 MB (22 MB são o `.wasm`), `licenses/` 0,2 MB. Os binários só ligam a bibliotecas do sistema
  (`otool -L figcraft-server`: libSystem, libobjc, Foundation, libiconv). O hash dos patches no script é
  `cat patches/figcraft/*.patch | shasum -a 256` (`build-figcraft.sh:57`).
- **Bundle**: `scripts/bundle-app.sh:35-42` copia `vendor/figcraft/{bin,web,licenses}` para `Contents/Resources/figcraft/`
  quando existe (senão só avisa) e assina cada binário com `--options runtime` (+ `--timestamp` no release); copia
  `Resources/NOTICE-figcraft` sempre (hoje ele cita só os patches 0001–0002; faltam 0003–0005). No `Collie.app`
  atual: `Resources/figcraft` 114 MB de 216 MB; `drawio` 36 MB.
- **dmg**: `Collie-0.1.0.dmg` = 98,6 MB (UDZO). `vendor/figcraft` em `tar.gz` = 51,4 MB.
- **CI**: `.github/workflows/release.yml` (tag `v*` ou manual, `macos-26`, `timeout-minutes: 330`) guarda
  `vendor/figcraft` em `actions/cache` com chave `hashFiles('scripts/build-figcraft.sh','patches/figcraft/**')` e só
  compila sem cache; notariza com `COLLIE_NOTARY_TIMEOUT: 14400` (4 h de espera, `release.yml:97`, `release.sh:54`);
  publica `Collie-<v>.dmg` e a cópia `Collie.dmg` (com `gh release upload --clobber` se a release já existe,
  `release.yml:114`) para o link `releases/latest/download/Collie.dmg`.
- **Daemon**: `Sources/collied/main.swift:73` resolve `COLLIE_FIGCRAFT_DIR` ou `<Helpers>/../Resources/figcraft` e põe
  em `config.figcraftDir` (opcional). `CommandRouter.swift:178` cria `FigcraftServer(binary: <dir>/bin/figcraft-server,
  dataDir: <root>/design/server)` e `DesignService(figcraftDir:)` usa `<dir>/bin/figcraft-cli`: um `figcraft-cli mcp`
  por (chamador, arquivo) (`DesignService.Key`). Ambos guardam o caminho em `let`, fixo na vida do daemon. Sem
  binário, `ensureRunning` lança `FigcraftServer.notBundled`. `DesignService.commandList` (`list_commands`) é lido uma
  vez por daemon ("the registry is fixed per figcraft build", `DesignService.swift:62-63,363-368`) e `stop()`
  (`:724`) não o limpa. `FigcraftServer.hold(_:)` é um `Bool` usado pelo backup (`DataBackup.swift:77,95`).
  `FigcraftServer.stop()` (TERM, KILL após 2 s) e `DesignService.stop()` (fecha todos os clientes) existem; um servidor
  que morre volta sozinho e o painel reconecta; os arquivos de design ficam em `<root>/design/server`.
- **Rotas**: `android.*` tem rota própria com `adminOnly` antes do despacho de plug-ins (`CommandRouter.swift:359`,
  `AndroidCommands.swift:8`). `design.*` cai no despacho de plug-in (`CommandRouter.swift:374-377`) e
  `designCommand` aceita terminal (`DesignCommands.swift:10`); `exposedToMCP: false` só esconde do MCP.
- **Painel**: `DesignPanel.webDirectory` (`static let`, uma vez) procura `Bundle.main/figcraft/web`, depois
  `COLLIE_FIGCRAFT_DIR/web` do **app**, depois (DEBUG) `vendor/figcraft/web` (`DesignPanel.swift:159-168`): ordem e
  ambiente diferentes dos do daemon (`main.swift:73`, ambiente do launchd). O `WKURLSchemeHandler` só é registrado no
  `init` se existe `webRoot` (`DesignPanel.swift:183`): um painel criado sem motor nunca ganha handler. Sem motor:
  "Motor de design indisponível / Rode scripts/build-figcraft.sh" com **Reconectar**. `design.link` responde
  `{editLink}` (`DesignService.swift:408`).
- **Orientação dos agentes**: com `designFirst == .figcraft`, `CollieOrientation.swift:98-102` manda o Pastor abrir um
  painel de design, sem olhar se o motor existe.
- **Preferências**: páginas `aparencia, terminal, desenho, memoria, plugins, celular, android`; o título de `desenho` é
  **"Desenho e sandbox"** (`PreferencePage.swift:12`) e ela tem `designSection` e `sandboxSection`
  (`PreferencesView.swift:144`). A página Android é o molde de UI: comandos `android.status/install/cancel` (só app,
  `adminOnly`), `AndroidSetupModel.swift` só decodifica o status; o poll fica em `AndroidPreferences.swift:49` (1 s com
  job, 3 s sem) e o selo da barra num laço de 5 s (`PreferencesView.swift:85`).
- **Download que já existe**: `AndroidDownload.fetch` (daemon): `URLSession` efêmera, `URLRequest` com timeout 60 s e
  sem retomada (`AndroidDownload.swift:150`), só `https` em hosts listados (`github.com` restrito a `/adoptium/`),
  cada redirect conferido; `verify(_:sha256:)` em streaming. Diferenças do caso figcraft: o hash do JDK vem da API da
  Adoptium (não fixado no app) e não há checagem de assinatura; o staging fica em `<sdk>/.collie-staging` e
  `AndroidInstaller.place` **nunca substitui** destino existente e recusa link que sai do arquivo
  (`AndroidInstaller.swift:157-173`). Troca de instalação existente não tem precedente no código.
- **Raiz**: `Paths.defaultRoot` = `~/Library/Application Support/Collie`. Terminal sandboxado não escreve na home fora
  do projeto e caches (`SandboxProfile.swift:140`) e os dados do Collie nunca são liberáveis
  (`SandboxGrants.swift:44`): um agente sandboxado não consegue trocar o motor instalado. Backup (`DataBackup`) não
  inclui o motor.
- **Assinatura**: `collied` tem hardened runtime (`flags=0x10000(runtime)`), sem entitlements; o identificador de
  assinatura do servidor hoje é `figcraft-server` (o do CLI, `figcraft-cli`).
- **Licença**: MIT/Apache-2.0 (figcraft) + OFL-1.1 (fontes embutidas): redistribuir num arquivo separado é permitido
  desde que vão `licenses/` e o NOTICE.

## Metas

1. O dmg do Collie não leva o figcraft; o release do app não compila Rust.
2. Preferências › Desenho e sandbox mostra o estado do motor (ausente, baixando, instalado vX, atualização disponível,
   erro) com **Baixar**, **Cancelar**, **Atualizar**, **Remover**, e progresso em bytes.
3. O motor baixado é verificado (sha256 fixado no app; assinatura Developer ID Application do time, com identificador)
   antes de ser usado; um arquivo que não confere nunca é extraído nem executado.
4. O daemon resolve o motor (Application Support e bundle), troca de motor sem reiniciar o daemon, sem janela em que o
   servidor e o CLI vêm de builds diferentes, e sem perder arquivos de design.
5. Sem motor, o painel Design, `collie design *` e a orientação dos agentes levam a "baixe o motor em Preferências",
   não a "rode scripts/build-figcraft.sh" nem a um agente tentando instalar.
6. Um workflow próprio compila, assina, notariza e publica o motor só quando os insumos do pin mudam (ou à mão).
7. Quem tem v0.1.0 (motor embutido) continua funcionando; o build local de desenvolvimento continua funcionando sem rede.

## Não metas

- Atualização automática do motor ou do app (Sparkle etc.): a atualização disponível vem de um app novo que fixa um
  motor novo.
- Manifesto remoto assinado / canal de atualização do motor independente do app (ver Abordagens).
- Retomar download interrompido: rede caiu → falha (timeout de 60 s por requisição) e **Tentar de novo** recomeça do
  zero (51,4 MB).
- Intel / macOS < 15.
- draw.io (`vendor/drawio`, 36 MB): mesmo padrão serve depois (seção Extensão), não entra aqui.
- Defender contra código sem sandbox rodando como o mesmo usuário (terminal livre, outro app, `launchctl setenv`): ele
  já pode trocar `~/.zshrc`. A cadeia aqui protege contra rede, CDN/GitHub comprometido e agentes sandboxados.
  Consequência assumida: a re-checagem de assinatura na subida do servidor (§4) é TOCTOU contra esse mesmo usuário
  (checa, depois `posix_spawn`); ela pega troca acidental ou por ferramenta, não um atacante local.
- Compartilhar o motor entre raízes: é um motor por raiz (`<root>/figcraft`); cada `--root` de dev/teste baixa o seu.

## Anti-metas

- O app baixar e executar algo que não confere com o hash fixado no pin do bundle assinado.
- Download sem o usuário clicar (inclusive "baixa ao abrir o painel Design"), ou disparado por agente/terminal.
- Apagar ou mexer em `<root>/design/` (arquivos do usuário) ao instalar, atualizar ou remover o motor.
- A release do motor virar a "latest" do repo e quebrar `releases/latest/download/Collie.dmg`.
- Release do app que fixa um motor que não existe publicado ou cujo hash difere.

## Abordagens consideradas

**A. Hash fixado no app + release própria por versão do motor (recomendada, aprovada).** Um arquivo no repo
(`Resources/figcraft-engine.json`) diz versão, URL, tamanhos, sha256 e team ID do asset; vai como recurso do bundle.
A assinatura do app sela o recurso (adulterá-lo quebra a assinatura do app, que o Gatekeeper confere na abertura do
app em quarentena); o daemon não reconfere o selo em runtime. O daemon só aceita esse arquivo exato. Atualizar o
motor = workflow publica → commit do novo pin → próximo release do app. Simples, sem chave nova, nenhum servidor no
caminho de confiança (GitHub só entrega bytes). Custo: um motor novo só chega com um app novo — ok, porque o
`DesignService` depende dos patches (ex.: 0005 fontes em runtime), então motor e app já andam juntos (ver Pendente do
dono, P1).

**B. Manifesto remoto assinado (ed25519/minisign) que o app consulta.** Permite motor novo sem release do app.
Custo: chave de assinatura nova para guardar e girar, formato de manifesto, rollback/freeze attacks (versão mínima,
expiração), e o app passa a aceitar binários que o app assinado nunca viu. Não compensa enquanto motor e app mudam
juntos.

**C. Só confiar na assinatura Developer ID + notarização (sem hash).** Qualquer binário do time passaria, inclusive um
motor antigo com bug conhecido (downgrade). O hash fixa o arquivo exato; a assinatura fica como segunda camada.

**Quem baixa — daemon (recomendado) vs app.** O daemon é quem executa o motor, segue rodando com a janela fechada, e
escreve em `<root>` (é dele); o molde de download (allowlist, hash em streaming) já está lá. O app baixar exigiria o
app escrever em `<root>` e avisar o daemon para trocar; ganha nada. Rodar sob launchd não atrapalha: Application
Support não é pasta protegida por TCC.

## Design

### 1. O pin (`Resources/figcraft-engine.json`)

```json
{ "version": "0.7.0-c1", "figcraft": "v0.7.0", "commit": "47438dd4a2e8b49a7e6bb3dfd480262dadc37f12",
  "inputs": "<ver abaixo>",
  "url": "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v0.7.0-c1/figcraft-0.7.0-c1-arm64.tar.gz",
  "size": 51400000, "unpackedSize": 114000000, "sha256": "<64 hex>", "teamId": "<TEAMID>" }
```

- `version` = tag do figcraft + `-c<N>` (revisão do Collie). `N` sobe à mão quando `inputs` muda.
- `inputs` = algoritmo exato, num script só (`scripts/figcraft-inputs.sh`, usado pelo workflow e conferido por teste):
  `LC_ALL=C`; lista ordenada de `scripts/build-figcraft.sh`, `scripts/package-figcraft.sh`,
  `scripts/figcraft-inputs.sh`, `.github/workflows/figcraft.yml` e `patches/figcraft/*.patch`; para cada um, a linha
  `<sha256>  <caminho relativo>`; `inputs` = sha256 dessas linhas juntas. (Não é o `hashFiles()` do Actions, que é
  interno.) Mudar qualquer um desses, inclusive flags de assinatura no workflow, exige `-c<N+1>`.
- `teamId` fica **só** no pin (o `engine.json` do asset não o traz: o asset não é fonte de confiança de si mesmo).
- `unpackedSize` = bytes do diretório extraído, para a checagem de espaço.
- `bundle-app.sh` copia o arquivo para `Contents/Resources/`. O daemon o lê de
  `<Helpers>/../Resources/figcraft-engine.json`. `COLLIE_FIGCRAFT_PIN` (outro pin por ambiente) só existe em build
  DEBUG/testes: em release, trocar o pin por env trocaria URL, hash e time. `COLLIE_FIGCRAFT_DIR` continua como hoje
  (mesmo usuário está fora do modelo de ameaça).

### 2. O asset

`figcraft-<version>-arm64.tar.gz` com `figcraft/{bin/figcraft-server,bin/figcraft-cli,web/…,licenses/…,NOTICE-figcraft,
engine.json}`; `engine.json` = `{version, commit}`. Empacotado com `COPYFILE_DISABLE=1 tar --no-xattrs
--no-mac-metadata` (sem `._*`, sem `com.apple.provenance`). Os dois binários assinados Developer ID Application com
hardened runtime, `--timestamp` e identificadores `figcraft-server` / `figcraft-cli`, notarizados (zip de `bin/` ao
`notarytool`; ticket não grampeia em Mach-O solto). Mora numa **release própria do repo público**
`figcraft-v<version>`, `--prerelease` (o `/releases/latest` ignora prerelease; `--latest=false` vai junto só por
clareza). Tar, gzip e `--timestamp` não são reprodutíveis: rebuildar a mesma versão dá outro sha256, por isso uma
versão publicada nunca é refeita (§9). Mais um `.sha256` ao lado, para humanos.

### 3. Instalação (daemon, `FigcraftInstaller`, actor)

1. Usuário clica **Baixar** (o botão mostra o tamanho do download formatado: "Baixar motor de design (51,4 MB)"). O
   app chama `design.engine.install`. O clique é a confirmação (decisão aprovada); não há download sem clique.
   `install` com job ativo devolve o mesmo job (não começa outro).
2. Espaço livre em `<root>` ≥ `size` + `unpackedSize` + 100 MB de margem; senão erro "Espaço insuficiente".
3. `fetch` = `AndroidDownload.fetch` com a allowlist ampliada: `github.com` também sob
   `/ysraelmoreno/collie/releases/download/figcraft-v` (sem `..`). URL vem só do pin, nunca de argumento. Destino
   `<root>/.figcraft-staging/asset.tar.gz`. Progresso `(bytes, total)` no job. Rede caiu → `failed` (sem retomada).
4. **sha256 do arquivo inteiro antes de qualquer extração** (`AndroidDownload.verify`). Não bateu → apaga o staging,
   job `failed` com "O arquivo baixado não confere (sha256). Nada foi instalado." e **sem retry automático** (botão
   **Tentar de novo**). Nada é extraído.
5. `/usr/bin/tar -xzf` em `<root>/.figcraft-staging/figcraft`. Depois, varredura do extraído: recusa qualquer symlink,
   arquivo não regular, setuid/setgid; força `go-w`. Confere layout: os dois executáveis, `web/index.html`,
   `engine.json.version == pin.version`.
6. Assinatura de cada binário: `SecStaticCodeCheckValidityWithErrors` com `kSecCSStrictValidate |
   kSecCSCheckAllArchitectures` e o requisito
   `identifier "<figcraft-server|figcraft-cli>" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "<teamId do pin>"`
   (só Developer ID Application do time, com o identificador certo; não aceita Apple Development nem Mac App
   Distribution). Redundante com o hash de propósito: pega um pin errado num commit. Nos testes o checador é
   injetado; o caminho real com Security.framework só é provado à mão (Verificação).
7. `xattr -dr com.apple.quarantine`, se houver (§4). `URLResourceValues.isExcludedFromBackup = true` no diretório.
8. **Troca** (§5): toma o `hold` do servidor, para clientes e servidor, troca `<root>/figcraft` com o staging, solta.
9. Apaga o staging (que agora contém o motor antigo, se havia). Job `done`.

`design.engine.cancel` cancela a Task (cancela o download), limpa o staging. `design.engine.remove`: recusa com
`busy` se há job ou `hold` ativo; senão faz a troca do passo 8 com "nada" (renomeia `<root>/figcraft` para o staging)
e apaga o staging. Nunca toca `<root>/design/`.

### 4. Gatekeeper, quarentena, hardened runtime (binário baixado e executado pelo daemon)

- **Quarentena**: `com.apple.quarantine` é posta por quem baixa, quando é app com `LSFileQuarantineEnabled` ou chama a
  API de quarentena; `URLSession` num processo comum não põe. Logo o `posix_spawn` do daemon **não** passa pelo
  Gatekeeper (syspolicyd só avalia na primeira execução de arquivo em quarentena). A segurança vem do hash +
  requisito de assinatura feitos pelo próprio Collie. O passo 7 remove a quarentena se algum caminho futuro a puser.
  Confirmar uma vez no teste manual: `xattr -l` nos arquivos instalados.
- **Kernel/AMFI**: em arm64 todo Mach-O precisa de assinatura válida; página adulterada = processo morto.
- **Hardened runtime / library validation do `collied`**: só restringe dylibs carregadas *dentro* do `collied`. O
  figcraft é outro processo, com a própria assinatura; a library validation dele só vê bibliotecas do sistema
  (`otool -L`). Nada de entitlement novo no daemon.
- **Notarização**: política do projeto e útil se o arquivo for aberto à mão com quarentena; não é o que protege o
  fluxo normal.
- A cada subida do servidor (não a cada chamada), o daemon repete o passo 6 nos binários de App Support. Falhou →
  trata como ausente com "Motor alterado, baixe de novo". TCTOU assumido (Não metas).

### 5. Resolução e troca no daemon

`FigcraftEngine` (CollieDaemonKit, função pura testável): candidatos em ordem —
1. `COLLIE_FIGCRAFT_DIR` (sem checagem de versão);
2. `<root>/figcraft` (Application Support), se layout válido e `engine.json` legível;
3. `<Helpers>/../Resources/figcraft` (bundle: v0.1.0 e build local);
4. DEBUG: `vendor/figcraft` do repo.

(Ordem 2→3 é decisão aprovada; ver Pendente do dono, P2.)

Resultado: `{dir, version, source: env|appSupport|bundle|vendor}` ou ausente. Estado para a UI: `absent` |
`installed(v)` | `updateAvailable(installed, pinned)` (instalado ≠ pin; continua usável, decisão aprovada; ver P1) |
job `downloading/verifying/installing/failed/cancelled`.

**Só o daemon resolve.** `design.link` passa a responder `{editLink, web: "<dir>/web", version}` e o painel serve o
web desse diretório: app e daemon nunca escolhem diretórios diferentes (antes, ordem e ambiente diferiam).

`FigcraftServer` e `DesignService` deixam de guardar o caminho em `let`: recebem `engine: @Sendable () ->
FigcraftEngine?`, resolvido em `start()` e guardado junto com o processo; cada cliente novo usa o motor **do servidor
em execução** (nunca um CLI de build diferente do servidor).

**Troca sem janela** (install, update, remove): `hold` passa de `Bool` a contagem (backup e instalador seguram
independentes). Sequência: espera o backup soltar (≤ 60 s; senão `busy` "backup em andamento") → `hold` →
`design.stop()` (fecha os `figcraft-cli mcp`) → `figcraft.stop()` → `renamex_np(staging/figcraft, <root>/figcraft,
RENAME_SWAP)` (mesmo volume, APFS; atômico: nunca há instante sem um dos dois) ou `rename` se não havia motor →
`commandList = nil` e demais caches por build → solta o `hold` → apaga o staging. Durante o `hold`, `ensureRunning`
responde `.unavailable` "motor de design sendo trocado, tente de novo" e nunca cai para o bundle. Na subida do daemon,
`<root>/.figcraft-staging` órfão é apagado (é sempre o lado descartável: antes da troca é o novo incompleto, depois é
o antigo). Painéis Design abertos reconectam sozinhos (comportamento atual); arquivos ficam em `<root>/design/server`,
e o `stop()` (TERM) é o mesmo do backup.

Sem motor, `ensureRunning` lança `.unavailable` com mensagem por quem pede (substitui `notBundled`):
- app/CLI do dono (admin): "Motor de design não instalado. Baixe em Preferências › Desenho e sandbox (collie design
  engine install)";
- terminal: "Motor de design não instalado: peça ao usuário para baixá-lo em Preferências › Desenho e sandbox do
  Collie." (sem o comando: o terminal não pode rodá-lo).

**Orientação**: `CollieOrientation.text` recebe `figcraftAvailable: Bool`. Sem motor, `.figcraft` e `.ask` caem para a
linha de `.artifact` (página na Prévia) + "FigCraft indisponível (motor não instalado); se o usuário quiser FigCraft,
peça para baixá-lo em Preferências."

### 6. Comandos (só app: rota própria com `adminOnly`, como `android.*`)

Rota `if req.command.hasPrefix("design.engine.")` em `CommandRouter` **antes** do despacho de plug-ins, com
`try await adminOnly(r, peer:)`; `exposedToMCP: false`.

- `design.engine.status` → `{state, installed?: {version, source}, pinned?: {version, size}, job?: {phase, bytes,
  total, error?}}` (`pinned` ausente se o bundle não tem pin).
- `design.engine.install` → `{job}` na hora (o mesmo job se já há um).
- `design.engine.cancel`; `design.engine.remove` (`busy` com job ou `hold`; `notFound` se o motor ativo não é de App
  Support).

CLI: `collie design engine [status|install|remove]` com a credencial do app (como `android.*`).

### 7. UX

Preferências › **Desenho e sandbox**, nova seção "Motor de design" acima de `designSection`; selo na barra como o
Android (`↓` baixando, `!` erro ou atualização), lido no laço de 5 s já existente (`PreferencesView.swift:85`). Na
página, poll de `design.engine.status` 1 s com job, 3 s sem (como `AndroidPreferences`). Palavras-chave da página
ganham "motor baixar instalar remover atualizar". Tamanhos com `ByteCountFormatter` (`.file`).

```
Motor de design (FigCraft)
  ausente:      Necessário para o painel Design e `collie design`.   [Baixar (51,4 MB)]
  baixando:     ███████░░░  33,1 MB de 51,4 MB                        [Cancelar]
  verificando:  Conferindo assinatura…
  instalado:    v0.7.0-c1 · 114 MB em disco · Application Support      [Remover]
                (bundle: "v0.7.0 · embutido no app" e sem Remover)
  atualização:  Instalado v0.7.0-c1 · disponível v0.8.0-c1 (53,2 MB)   [Atualizar] [Remover]
                Os painéis Design abertos vão reconectar.
  erro:         Falhou: <mensagem>                                     [Tentar de novo]
```

**Remover** pede confirmação ("Os arquivos de design continuam; o painel Design fica indisponível até baixar de
novo."). Painel Design: o `DesignSchemeHandler` é registrado **sempre** no `init`, com raiz mutável (nil = 404), e a
raiz vem do `web` da resposta de `design.link` a cada `connect()`. Sem motor (erro `notInstalled` do daemon), o painel
mostra "Motor de design não instalado" + botão **Abrir Preferências** (página Desenho e sandbox) no lugar de
**Reconectar**.

### 8. Migração

- v0.1.0 instalada: não muda nada (só conhece o bundle).
- v0.1.0 → v0.2 (dmg sem motor): o motor sai junto com o app velho; o daemon novo acha `absent`; Preferências e o
  painel oferecem **Baixar**. Um clique, 51,4 MB. Arquivos em `<root>/design/` intactos. A nota da release diz isso.
- Volta de v0.2 para v0.1.0: v0.1.0 usa o próprio bundle; `<root>/figcraft` fica parado, inofensivo.
- Build local com `vendor/figcraft`: continua embutindo (decisão aprovada), `source: bundle` (ver P2).

### 9. CI e build local

- **Novo `.github/workflows/figcraft.yml`**: gatilho `push` em `main` com `paths` = os arquivos de `inputs` (§1) +
  `Resources/figcraft-engine.json`, e `workflow_dispatch`. Passos:
  1. lê o pin; confere `inputs` com `scripts/figcraft-inputs.sh` (falha "suba -c<N> e o inputs no pin");
  2. se a release `figcraft-v<version>` existe **publicada** com o asset: baixa e confere que o sha256/size do pin
     batem (pin com zeros = ainda não preenchido → imprime os valores e sai verde); diferente → falha. Existe como
     **draft** (rodada anterior caiu) → apaga o draft e segue;
  3. build **a frio** assumido (`target/` passa de GB, disputaria a cota de 10 GB e o workflow quase nunca acerta a
     chave); cache só de `vendor/figcraft-tools` e `~/.cargo/registry` com `restore-keys`;
  4. `scripts/build-figcraft.sh`; keychain temporário (script compartilhado com o `release.yml`); assina,
     notariza e empacota com `scripts/package-figcraft.sh`;
  5. `gh release create figcraft-v<version> --draft --prerelease --latest=false`, sobe `.tar.gz` e `.sha256`,
     confere o download do asset, e **só então** publica (`gh release edit --draft=false`). Nunca `--clobber`;
  6. imprime `sha256`/`size`/`unpackedSize` para o commit do pin. Timeout 300 min (build frio ~40 min + notarização
     até 4 h).
  Imutabilidade é regra do workflow: o "Immutable Releases" do GitHub vale para o repo inteiro e quebraria o
  `gh release upload --clobber` do `release.yml:114`; não ligar.
- **Atualizar o pin**: commit à mão com os valores impressos (minha chamada 8).
- **`release.yml`**: some o cache e o build do figcraft; novo passo barato "Conferir motor": baixa o asset do pin,
  confere `sha256` e roda o mesmo requisito de assinatura do §3.6 (`codesign --verify --strict -R='<requisito>'` nos
  dois binários extraídos). Falha o release se o motor fixado não está publicado, o hash difere ou a assinatura não
  bate. `timeout-minutes` cai de 330 para 270 (a espera de notarização de 4 h, `COLLIE_NOTARY_TIMEOUT: 14400`, fica).
- **`release.sh`**: exporta `COLLIE_BUNDLE_FIGCRAFT=0`; depois do bundle, falha se `Contents/Resources/figcraft`
  existir.
- **`bundle-app.sh`**: copia `figcraft-engine.json` sempre; copia o motor só se `vendor/figcraft` existe e
  `COLLIE_BUNDLE_FIGCRAFT` ≠ `0` (padrão: copia; decisão aprovada). O aviso "vendor/figcraft missing" vira nota
  ("motor fica para download").
- `NOTICE-figcraft`: lista os 5 patches (0001–0005) e diz "baixado sob pedido para `<root>/figcraft/`, licenças em
  `figcraft/licenses/`"; o mesmo texto vai dentro do asset.

### 10. Tamanho, offline, custo

- dmg: 98,6 MB − ~51,4 MB ≈ **47 MB**; app instalado 216 → ~102 MB. Download do motor 51,4 MB, 114 MB em disco, fora
  do Time Machine. (Estimativas: `tar.gz` medido; o UDZO usa zlib como o gzip. Sem rede/CI não dá para medir o dmg
  novo.)
- Offline / primeiro uso: Collie abre e funciona sem o motor; só design fica indisponível com a mensagem de baixar.
  Download falho não deixa nada pela metade (staging + troca atômica).
- CI: release do app sem Rust (−20 a 40 min a frio). O workflow do motor roda só quando os insumos mudam, sempre a
  frio.
- Riscos: (a) pin com hash errado → todo usuário vê "não confere": mitigado pelo "Conferir motor" do `release.yml` e
  pelo passo 2 do `figcraft.yml`; (b) release do motor apagada → 404; nunca apagar tags `figcraft-v*`; (c) GitHub fora
  do ar → só o primeiro download falha; (d) mudar o `figcraft.yml` (até comentário) exige `-c<N+1>` e um build novo:
  custo aceito em troca de pegar mudança de flags.

## Decisões do dono

- dmg sem figcraft; botão em Preferências com progresso, remover e atualizar.
- Ordem de busca: Application Support → bundle.
- Sem motor, painel mostra "baixe o motor" em vez de erro.
- Workflow separado, só quando o pin muda; asset assinado Developer ID e notarizado; o app guarda o sha256 fixado.
- Aprovadas em 2026-11-16 (eram minhas chamadas 4–7): versão `0.7.0-c<N>` / tag `figcraft-v0.7.0-c<N>`; motor
  desatualizado continua usável com aviso; build local continua embutindo quando existe `vendor/figcraft`; só o botão
  de baixar (com o tamanho) como aviso antes do download.

## Pendente do dono

**P1. Motor desatualizado continua usável (decisão aprovada) × motor e app andam juntos.** A revisão aponta tensão:
a abordagem A se justifica porque o `DesignService` depende dos patches de cada versão (ex.: 0005), então um motor
antigo com app novo pode quebrar comandos de design de um jeito confuso; e a re-checagem na subida confere só a
assinatura, não o hash, então qualquer motor antigo assinado pelo time roda (downgrade).
- *Opção atual (aprovada)*: instalado ≠ pin roda, com "Atualização disponível". Vantagem: quem atualiza o app offline
  continua desenhando. Custo: combinação app/motor não testada em produção; downgrade aceito.
- *Opção do revisor*: gravar o sha256 do asset instalado em `<root>/figcraft/.collie-installed`; motor de App Support
  só roda se bater com o pin; senão estado "Atualize o motor de design (53,2 MB)" e o painel bloqueia até atualizar;
  motor mais novo que o pin aparece como "Reinstalar".
- *Recomendação*: a do revisor. Pela abordagem A, app novo e motor novo sempre chegam juntos; bloquear custa um
  clique de 51 MB uma vez por troca de pin (poucas por ano), e elimina a única combinação que nunca foi testada. O
  caso offline-depois-de-atualizar é raro e a mensagem é clara.
- Afeta o plano: Tasks 1, 2, 3 e 5 (marcadas "depende da decisão P1").

**P2. Ordem App Support → bundle (decisão aprovada) × build local de dev.** O app de dev usa a mesma
`Paths.defaultRoot`; se o dono baixou o motor uma vez, o `vendor/figcraft` recém-patchado embutido no build local é
ignorado e ele testa o motor velho sem perceber.
- *Opção atual (aprovada)*: App Support → bundle. Dev precisa remover o motor baixado ou usar `COLLIE_FIGCRAFT_DIR`.
- *Opção do revisor A*: bundle vence quando existe. *Opção B*: App Support só se bater com o pin.
- *Recomendação*: bundle vence quando existe (opção A). Em release o bundle nunca tem motor (`release.sh` falha se
  tiver), então em produção a ordem é indiferente e a v0.1.0 nem lê App Support; a ordem só decide no build local, e
  aí o certo é o motor que acabou de ser compilado. A opção B não resolve: patch novo sem subir o pin ainda perde para
  o App Support que bate com o pin.
- Afeta o plano: Task 1 e Task 6 (marcadas "depende da decisão P2").

## Minhas chamadas (conferir)

1. **Hash fixado no app (A), sem manifesto remoto.** "Atualização disponível" só aparece depois de atualizar o app.
2. **Daemon baixa**, não o app (o agente não tem comando para isso: rota `adminOnly`).
3. **Diretório `<root>/figcraft`** (= `~/Library/Application Support/Collie/figcraft`), um por raiz, sem versões lado a
   lado; troca por `RENAME_SWAP`.
4. **Versão `0.7.0-c<N>`** (aprovada) e tag `figcraft-v0.7.0-c1`.
5. **Motor desatualizado continua usável** (aprovada; ver P1).
6. **Sem confirmação extra** (aprovada) além do clique em "Baixar (51,4 MB)"; Remover pede confirmação.
7. **Build local continua embutindo** (aprovada; ver P2).
8. **Pin atualizado por commit manual** depois do workflow (não por PR automático): menos permissões no workflow.
9. **Requisito de assinatura com identificador e Developer ID Application**, conferido no install, a cada subida do
   servidor e no "Conferir motor" do `release.yml`; team ID só no pin.
10. Tamanho no botão é do download, não do disco; todos os tamanhos em MB decimais do `ByteCountFormatter`.
11. **Build do motor sempre a frio** no CI (sem cache de `target/`).
12. **Só o daemon resolve o diretório**; o painel usa o `web` do `design.link`.

## Fica para quem construir

- Nomes exatos dos tipos (`FigcraftEngine`, `FigcraftInstaller`).
- Extrair `AndroidDownload.fetch`/`verify` para um `Download` comum ou só ampliar a allowlist.
- Forma do script de keychain compartilhado entre `release.yml` e `figcraft.yml`.

## Extensão (fora deste escopo)

draw.io (`vendor/drawio`, 36 MB, só web, sem binário): mesmo pin + release `drawio-v…` + instalador; sem passo de
assinatura (não há Mach-O), só hash.

## Verificação

Testes só com `--filter`, nunca a suíte inteira:

- `FigcraftEngineTests`: ordem de candidatos; layout inválido ignorado; `updateAvailable` quando versão ≠ pin;
  staging órfão apagado.
- `FigcraftPinInputsTests` (Task 7): `inputs` do pin = saída de `scripts/figcraft-inputs.sh`.
- `FigcraftInstallerTests` (fetch e checador de assinatura injetados, sem rede): sucesso; sha256 errado → nada
  extraído, motor anterior intacto, staging limpo, sem retry; symlink/setuid no tar → recusado; assinatura recusada;
  espaço insuficiente com `size + unpackedSize + 100 MB`; cancelar; install concorrente devolve o mesmo job; remover
  com `hold` → `busy`; remover não toca `<root>/design/`.
- `FigcraftServerTests` / `DesignCommandTests`: troca sob `hold` sem cair no bundle; cliente novo usa o motor do
  servidor em execução; `reloadEngine` zera `commandList`; mensagens admin × terminal.
- `DesignEngineCommandTests`: `design.engine.*` vindo de terminal → recusado (`adminOnly`); fora do MCP.
- `CollieOrientationTests`: sem motor, `.figcraft` cai para a linha de página.
- `DesignPanelTests`, `DesignEngineModelTests`, `PreferencePageTests`: handler registrado sem motor; raiz vinda do
  `design.link`; estado "não instalado"; linhas da UI; selo.
- Só à mão (o checador real de Security.framework não roda nos testes): com o app de release instalado e o primeiro
  `figcraft.yml` publicado, Baixar, `xattr -l` e `codesign -dv -R='<requisito>'` nos binários de `<root>/figcraft`,
  abrir um painel Design, Remover, Baixar de novo.
- `release.yml`: num `workflow_dispatch` de tag de teste, conferir que o dmg não tem `Contents/Resources/figcraft` e
  medir o tamanho.

## Tarefas (independentes, em ordem sugerida)

1. Pin + `FigcraftEngine` (resolução, estado, limpeza) + testes.
2. Servidor e clientes com motor por closure, `hold` em contagem, troca, `reloadEngine` (caches), mensagens admin ×
   terminal, `design.link` com `web`, orientação sem motor.
3. `FigcraftInstaller` (download, hash, extração segura, assinatura, quarentena, exclusão do backup, troca, cancelar,
   remover) + allowlist.
4. Rota `design.engine.*` com `adminOnly` + CLI.
5. Preferências › Desenho e sandbox: seção "Motor de design", poll, selo.
6. `DesignPanel`: handler sempre registrado, raiz do `design.link`, estado "não instalado".
7. `figcraft-inputs.sh` + `package-figcraft.sh` + `figcraft.yml` (draft → publish) + keychain compartilhado + NOTICE;
   `inputs` do pin preenchido.
8. `release.yml` sem figcraft + "Conferir motor" (hash + assinatura) + timeout; `release.sh`; `bundle-app.sh`;
   `docs/release.md`.
