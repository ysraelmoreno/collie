# Atualizador automático do Collie — design

Status: rascunho para o dono revisar (2026-11-17), revisado (revisão independente aplicada em 2026-11-17: B1, B2,
I1–I11 e menores). Nada implementado. Plano: `docs/superpowers/plans/2026-11-17-update-downloader.md`.

## Intenção e porquê

Hoje cada versão nova do Collie exige ir ao site ou ao GitHub, baixar o `Collie.dmg`, arrastar para
`/Applications` e reabrir. O dono quer que o app descubra sozinho que há versão nova, baixe em segundo plano, confira
e instale com um clique, **sem derrubar sem aviso os terminais e agentes que estão rodando**. O Collie não está na
App Store, então não há atualizador do sistema: é preciso um próprio ou uma biblioteca.

O que tornaria isto um fracasso mesmo funcionando: instalar e fechar agentes no meio do trabalho; aceitar um app que
não é do time AG8JQAH6YB; deixar um agente num terminal trocar o app entre a verificação e a instalação; tratar a
release do motor `figcraft-v*` como versão do app; um laço de downloads que falham sem fim; mandar qualquer
identificador do usuário para fora; validar o atualizador derrubando o daemon real do dono.

## Estado atual (verificado no código, main em 0fb2323)

- **Release**: `.github/workflows/release.yml` roda em tag `vX.Y.Z` (ou manual com tag existente), chama
  `scripts/release.sh` e cria a GitHub Release com `Collie-<v>.dmg`, `Collie-<v>.dmg.sha256` e as cópias idênticas
  `Collie.dmg`/`Collie.dmg.sha256` (link estável `releases/latest/download/Collie.dmg`). Se `gh release view "$TAG"`
  acha a release (inclusive um **draft**), só faz `gh release upload --clobber` (`release.yml:105-106`). Notas: um
  texto fixo + `--generate-notes`. O `gh release create` com assets cria um draft, sobe os assets e só então publica
  (<https://cli.github.com/manual/gh_release_create>); se o job morre no meio, sobra um draft que a rodada seguinte
  só atualiza e nunca publica. O `figcraft.yml:78-83` já apaga drafts órfãos; o `release.yml` não.
- **Tamanho**: `Collie-0.1.1.dmg` publicado = 41 711 021 bytes (41,7 MB, `gh release view v0.1.1`).
- **Assinatura**: `release.sh` assina o app (hardened runtime, `--timestamp`), confere cada Mach-O, cria o dmg UDZO,
  assina o dmg, notariza **o dmg** e grampeia **só o dmg** (`release.sh:67`). O `.app` de dentro não tem ticket
  próprio.
- **Versões**: `CFBundleShortVersionString` (`Resources/Info.plist`, `0.1.0`; o CI sobrescreve com a tag).
  `CFBundleVersion` é fixo em `"1"`. O daemon lê a versão do bundle **uma vez, ao subir**
  (`DaemonConfig.bundleVersion`, `Daemon.swift:132`, chamado em `collied/main.swift:116`): informa a versão com que
  subiu.
- **Daemon e LaunchAgent**: `DaemonLauncher.ensureRunning` (`Sources/CollieClient/DaemonLauncher.swift:99-109`)
  reescreve o plist `dev.collie.daemon` e faz `bootout` + `bootstrap` **só se o plist mudar** (o plist leva o caminho
  do `collied` do app aberto). `KeepAlive: true` (`:34`): se o `collied` morrer, o launchd sobe o binário que estiver
  no caminho.
- **O que de fato reinicia o daemon** (e fecha os terminais) — conferido:
  1. `kickstart -k`: o botão **Reiniciar serviço** do banner de serviço desatualizado (`CollieApp.swift:215-229`), a
     confirmação do import de dados (`:470`) e `scripts/dev/reload.sh:25` (que faz `rsync` para `/Applications` e
     logo depois `kickstart -k`).
  2. Abrir o app de **outro caminho** (ex.: `build/Collie.app`): o plist muda e há `bootout`/`bootstrap`.
  3. **Escrever por cima** de um Mach-O em execução (`cp` sobre arquivo existente, `rsync --inplace`): as páginas
     do binário assinado mudam, o kernel mata o processo por *Code Signature Invalid* e o `KeepAlive` sobe o binário
     novo (<https://developer.apple.com/forums/thread/696460>, <https://developer.apple.com/forums/thread/781548>).
  4. Qualquer morte do daemon antigo (crash, logout) sobe o binário novo pelo `KeepAlive`.
  Trocar o `.app` **por rename** (inode novo, `renamex_np`, Finder) no mesmo caminho **não** reinicia: o processo
  antigo segue com o inode antigo. O app não reinicia sozinho por `BuildID` (`CollieApp.swift:197-229`): só mostra o
  banner.
- **Bundle visto pelo daemon antigo**: o daemon resolve `collie`, `collie-ctty`, `Resources/scrcpy-server`,
  `weblibs`, `Fonts` e o pin **por caminho** (`collied/main.swift:65-101`). Depois de trocar o bundle: todo spawn novo
  usa o `collie-ctty` novo (`TerminalRegistry.swift:27-32`, conferido por spawn); hooks, `statusLine`, notify e MCP
  dos agentes, mesmo os já rodando, chamam `…/Helpers/collie` **novo** contra o daemon antigo
  (`AgentLaunch.swift:44,101,107`); o MCP novo anuncia ferramentas compiladas no CLI (`collie/MCPServer.swift`). O
  pin só é lido ao subir (`CommandRouter.swift:186`). Não há versão de protocolo no handshake.
- **Admin**: `SignedAppCheck` (`AdminPeerCheck.swift`) aceita como admin quem bate com o cdhash do
  `Contents/MacOS/Collie` em disco ao lado do `collied`, relido quando o arquivo muda: quem estiver naquele caminho
  vira o app confiável.
- **Sandbox dos terminais**: o modo padrão é `.open` (`Daemon.swift:104`): escrita liberada em toda a conta, exceto
  os internos do Collie: `<root>`, o subpath do app, os LaunchAgents `dev.collie.*` e os ancestrais deles como
  literal (`SandboxProfile.swift:110-125`). **Um agente pode escrever em `/Applications/<outro nome>`.**
- **Local do app**: `Config.tccWarning` (`CollieApp.swift:29`) avisa em `~/Documents`, `~/Desktop`, `~/Downloads`.
  Nada trata App Translocation. `Config.root`/`Config.label` aceitam `COLLIE_ROOT`/`COLLIE_LABEL` **só em DEBUG**
  (`CollieApp.swift:12-19`); `bundle-app.sh` e `release.sh` compilam `-c release` (`bundle-app.sh:14`).
- **Moldes de download**: `AndroidDownload.fetch` (`AndroidDownload.swift:146-184`): sessão `.ephemeral` (sem
  cookies e sem cache em disco, mas com cache em memória), `URLRequest(url:timeoutInterval:)` sem cabeçalho próprio
  (o User-Agent padrão do CFNetwork expõe nome do binário e versão do Darwin), **sem limite de bytes**; todo
  redirect e a URL final checados por `allowed` (https, host da lista, porta padrão, sem credenciais; em
  `github.com` só `/adoptium/` e `/ysraelmoreno/collie/releases/download/figcraft-v`). `AndroidDownload.verify`
  (sha256). `FigcraftInstaller`: `Job{phase,bytes,total,error}`, staging 0700, sha256 antes de extrair e sem
  retentar, `scan`, `signedByTeam`, `stripQuarantine`, `renamex_np(RENAME_SWAP)`. O `busy` dele é
  `figcraft.isHeld` (`CommandRouter.swift:210`): cobre o backup (que segura o servidor) mas não o import.
- **Motor**: `FigcraftEngine.resolve` só usa o motor de `<root>/figcraft` se o marcador é o sha256 do pin
  (`FigcraftEngine.swift:36`): com pin novo, o desenho fica indisponível até baixar o motor novo (decisão P1 do
  spec do figcraft).
- **Workspace**: não há comando de admin para gravar o workspace (`workspace.*` não existe em `Commands.swift`).
- **Preferências**: `PreferencePage` = `aparencia, terminal, desenho, memoria, plugins, celular, android`. Sem página
  de atualizações. O app trata `NSApplication.willTerminateNotification` (`CollieApp.swift:334`); não há
  `AppDelegate`.
- **Build local do dono**: o `/Applications/Collie.app` do dono é assinado com "Collie Local" (sem TeamIdentifier).
- **Dependências**: SwiftPM só com SwiftTerm `exact: "1.99.0"`.

## Metas

1. Descobrir versão nova sozinho (na abertura e periodicamente) e avisar sem atrapalhar.
2. Baixar em segundo plano e verificar: sha256, dmg do time e notarizado, `.app` Developer ID do time AG8JQAH6YB,
   versão maior que a instalada.
3. Instalar com um clique, trocando o `.app` **só por rename**, de forma atômica, e reabrindo.
4. Nunca fechar terminais sem confirmação que diga quantos e quais estão ativos; permitir atualizar o app **sem**
   reiniciar o serviço, com contrato de compatibilidade explícito.
5. Avisar quando a versão nova traz pin de motor novo e que o desenho para até baixá-lo.
6. Zero identificadores na checagem; funcionar calado offline.
7. Validável sem tocar no daemon real do dono.

## Não metas

- Atualização delta, canal beta, rollout em fases.
- Instalar quando o usuário não tem permissão de escrita na pasta do app (pedir senha de admin): abre a página da
  release.
- Atualizar o motor figcraft junto (continua no fluxo próprio das Preferências; só oferecemos o atalho).
- Rebaixar versão por caminho automático (voltar para a versão anterior guardada é ação explícita, §4).
- Atualizar build local ("Collie Local", sem time): recusado, ela segue pelos scripts.
- Intel / Rosetta.

## Abordagens

### A. Sparkle 2

Fontes (lidas pelo revisor em 2026-11-17): <https://sparkle-project.org/documentation/>,
`/documentation/publishing/` ("you must cryptographically sign your updates"), `/documentation/customization/`,
`/documentation/custom-user-interfaces/`, `/documentation/eddsa-migration/`.

- **Como é**: framework SwiftPM, `SUFeedURL` com appcast RSS, `SUPublicEDKey` no `Info.plist`, chave Ed25519
  obrigatória (`generate_keys`, `sign_update`, `generate_appcast`). Aceita dmg, zip, tar e aar. Para app não
  sandboxed os serviços XPC são opcionais; o helper `Autoupdate` espera o app sair, troca e relança. Compara versões
  por `CFBundleVersion`. Tem delta. O delegate `SPUUpdaterDelegate` permite adiar
  (`updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`) e decidir o relançamento. UI própria é
  possível via `SPUUserDriver` (custom user interfaces): a UI **não** é impedimento.
- **Daemon launchd, terminais, Helpers sob o daemon antigo, motor figcraft**: o Sparkle não sabe de nada disso.
  Tudo o que §3–§5 descrevem teria de ser feito no delegate e num `SPUUserDriver` próprio, igual.
- **Custo**: dependência nova (framework + helpers a embutir e assinar com hardened runtime e timestamp em
  `bundle-app.sh`; o laço de `release.sh` que confere cada Mach-O passa a cobri-los); segundo segredo (chave EdDSA)
  no CI; appcast novo; `CFBundleVersion` teria de virar incremental (hoje é `"1"`); a troca do Sparkle não sabe da
  regra de proteção da irmã (§2) contra agentes no mesmo usuário. O revisor só achou documentada a conferência de
  assinatura Apple igual entre versões no contexto de migração de chaves; não confirmado para o fluxo normal.
- **Ganho real**: troca/relançamento maduros, instalação com senha de admin, delta.

### B. Atualizador próprio no molde do `FigcraftInstaller` (recomendada)

- Manifesto `update.json` como asset de cada release, pelo link estável
  `https://github.com/ysraelmoreno/collie/releases/latest/download/update.json`.
- Daemon: checa, baixa o `Collie-<v>.dmg` com limite de bytes, confere sha256 e a assinatura notarizada do dmg.
  App: monta o dmg, copia o `.app` para uma pasta irmã de nome único, confere a assinatura, troca por rename,
  confere de novo no caminho final, relança; reiniciar o serviço é passo separado e opcional.
- **Custo**: uma página de Preferências, um actor no daemon, uma rotina de troca no app, uma regra nova no perfil
  do sandbox; reaproveita `AndroidDownload.fetch/verify`, `signedByTeam`, `stripQuarantine`, o padrão `Job` + poll e
  o padrão de confirmação do import. Sem dependência nova, sem segredo novo.
- **Perde**: delta, senha de admin, maturidade do relançamento (cobrimos com testes de troca e o roteiro manual).

### C. Só avisar

Mostrar "Collie X disponível — Baixar". Não resolve o pedido; vira o **fallback** de B.

**Recomendação: B.** O difícil (daemon launchd, terminais, Helpers trocados sob o daemon antigo, sandbox dos
agentes, motor figcraft) é o mesmo nas duas e o Sparkle não resolve; ele cobra dependência, segundo segredo,
`CFBundleVersion` incremental e helpers a embutir. O resto do B já existe no código.

## Design

### 1. Fonte da verdade e canal

- **Manifesto** `update.json` (asset de cada release `vX.Y.Z`, gerado pelo CI):

  ```json
  {
    "format": 1,
    "version": "0.2.0",
    "tag": "v0.2.0",
    "dmg": "Collie-0.2.0.dmg",
    "size": 41711021,
    "sha256": "<64 hex do dmg>",
    "minimumSystemVersion": "15.0",
    "teamId": "AG8JQAH6YB",
    "figcraftEngine": "0.7.0-c1",
    "page": "https://github.com/ysraelmoreno/collie/releases/tag/v0.2.0"
  }
  ```

  Sem campo de notas: as notas de `--generate-notes` só existem depois da criação da release. O cartão mostra o
  link "Ver novidades no GitHub" (`page`).
  A URL do dmg **não** vem do manifesto: o cliente monta
  `https://github.com/ysraelmoreno/collie/releases/download/<tag>/<dmg>` e recusa `tag` fora de `^v\d+\.\d+\.\d+$`,
  `dmg` diferente de `Collie-<version>.dmg`, `tag` diferente de `v<version>`, `page` diferente de
  `…/releases/tag/<tag>`, `size` ≤ 0 ou > 500 MB.
- **Por que manifesto e não a API**: a API sem token tem limite de 60 pedidos/hora por IP. O link
  `releases/latest/download/<asset>` é um redirect que já ignora draft e prerelease; `figcraft-v*` é prerelease com
  `--latest=false`. A "latest" do GitHub é a mais recente por `created_at`, com `make_latest` verdadeiro por padrão
  (<https://docs.github.com/en/rest/releases/releases#get-the-latest-release>): um hotfix numa linha antiga
  viraria a latest. O CI passa `--latest=false` quando a tag não é a maior `vX.Y.Z` publicada (§6); o cliente ainda
  recusa downgrade.
- **dmg, não zip**: é o artefato que já existe, notarizado e grampeado.
- **Ordem de versões**: `X.Y.Z` como três inteiros; só oferece se `version > instalada` (`Bundle.main`, não o
  daemon).
- **Downgrade**: recusado no manifesto e no `Info.plist` de dentro do dmg (tem de ser igual a `version`).
- **Lista de recusados**: guarda o `sha256` do manifesto **só** quando o dmg baixado diverge desse sha256 ou a
  assinatura/versão de dentro é recusada; não baixa de novo esse sha256. 404, erro de rede, timeout, limite de
  bytes por rede truncada e cancelamento **não** entram: retentam na próxima checagem. Motivo: `gh release upload
  --clobber` apaga e sobe sem ordem documentada (<https://cli.github.com/manual/gh_release_upload>); um cliente pode
  ver o manifesto novo e levar 404 no dmg por alguns minutos. Um manifesto novo traz sha novo, que não está na
  lista.
- **Manifesto ausente** (404, releases sem `update.json`): "nada novo", sem erro visível.

### 2. Segurança

- **Download**: `fetch` ganha limite de bytes e cabeçalhos (ver tarefa no plano): manifesto até 64 KB, dmg até o
  `size` do manifesto; passou, cancela e falha. `User-Agent: Collie/<versão>` fixo; `requestCachePolicy =
  .reloadIgnoringLocalCacheData` e `urlCache = nil` na sessão do atualizador.
- **Hash**: sha256 do dmg inteiro antes de qualquer outra coisa.
- **dmg**: `SecStaticCodeCheckValidity` no dmg com o requisito `anchor apple generic and certificate
  leaf[subject.OU] = "AG8JQAH6YB" and notarized`. O ticket está grampeado no dmg, então a checagem vale offline. Se
  falhar, recusa (sem exceção para "rede"). O `spctl --assess` saiu: no app sem ticket próprio, offline ele falha
  com o mesmo código de uma rejeição e não acrescenta nada. Validar à mão que o requisito `notarized` passa offline
  num dmg grampeado; se não passar, o requisito fica só o do time e isso é dito no plano.
- **`.app`**: `signedByTeam(app, "dev.collie.app", "AG8JQAH6YB")` com `kSecCSStrictValidate |
  kSecCSCheckAllArchitectures | kSecCSCheckNestedCode`, e `collied`, `collie`, `collie-ctty` um a um com seus
  identificadores. O team ID é **constante do app**; o `teamId` do manifesto só precisa bater.
- **Irmã de nome único e o sandbox dos agentes** (o ponto crítico da segurança): no modo `open`, um agente pode
  escrever em `/Applications/qualquer-outra-coisa`, e o que estiver em `/Applications/Collie.app` depois da troca
  vira o app admin. Regras:
  1. A pasta irmã é criada com `mkdtemp("<pasta-mãe>/.Collie-update-XXXXXX")` (exclusiva, 0700): nunca reaproveita
     caminho existente nem mescla conteúdo plantado.
  2. O perfil do sandbox nega escrita em `^<pasta-mãe-do-app>/\.Collie-update-` (regra nova em
     `SandboxProfile`, modo `open` e `strict`). Como o checador mora no daemon, todo daemon capaz de atualizar já
     gerou esse perfil para todos os seus terminais.
  3. Depois do `renamex_np`, confere `signedByTeam` de novo **no caminho final** (que já é protegido pelo deny do
     subpath do app). Falhou: destroca (`renamex_np` de novo) e aborta com erro.
  4. Não verificado: se o Seatbelt checa o diretório-pai em `file-write-create` (o literal `/Applications` está
     negado como ancestral). Entra no roteiro manual (§8): se a criação da irmã por um terminal **já** é negada pelo
     literal, a regra 2 é redundante mas fica.
- **Quem pode publicar**: só o CI com os secrets do Developer ID. Quem tem push de tag dispara o CI; hoje só o
  dono.
- **EdDSA**: não (ver "Minhas chamadas" 4). Só agregaria com a chave **fora** do CI.
- **Hosts**: `AndroidDownload.allowed` ganha, em `github.com`, `/ysraelmoreno/collie/releases/latest/download/` e
  `/ysraelmoreno/collie/releases/download/v`. Os redirects para `objects.githubusercontent.com` /
  `release-assets.githubusercontent.com` já estão na lista. Manifesto decodificado estrito.
- **Falha de verificação**: estado `failed` com o motivo, staging e irmã apagados, nada tocado no app instalado.
- **Build local**: se o app instalado não é do time AG8JQAH6YB (`signedByTeam` no próprio `Bundle.main` falha), a
  página mostra "Build local: atualize pelos scripts" e não checa. Evita trocar o "Collie Local" do dono (que
  pediria TCC de novo para o app e o `collied`, e não teria o benefício do App Management do mesmo time).

### 3. UX

- **Checagem**: 60 s depois de abrir e a cada 12 h enquanto o daemon roda. Botão **Procurar agora**.
- **Página nova** `PreferencePage.atualizacoes`, título **"Atualizações"**, grupo **Interface**, ícone `↻`:
  - "Versão instalada 0.1.0 · última verificação há 2 h" (ou "sem conexão").
  - **Procurar atualizações automaticamente** (ligado) e **Baixar em segundo plano** (ligado).
  - Com versão nova: cartão "Collie 0.2.0 disponível · 41,7 MB", link "Ver novidades no GitHub", **Instalar…**,
    **Pular esta versão**, progresso.
  - Com a versão anterior guardada (§4): **Voltar para 0.1.0**.
  - Selo na barra lateral, como o do Android.
- **Aviso discreto**: selo e, uma vez por versão pronta, notificação do sistema (`Notifier`).
- **Pular esta versão**: guarda a versão em `UserDefaults`; some até sair uma maior.
- **Download em segundo plano**: ligado, baixa e verifica ao achar. Desligado, baixa ao clicar **Instalar…**.
- **Instalar…**: folha de confirmação com o estado pedido ao daemon (terminais abertos e ocupados; "ocupado" = o
  sinal de `targetBusy`):

  ```
  Instalar Collie 0.2.0
  Há 3 terminais abertos (2 agentes trabalhando agora: collie-dx, apps-dev).

  ( ) Atualizar só o app — os terminais continuam rodando.
      O serviço antigo segue até você reiniciá-lo. Os hooks e o MCP dos
      agentes já passam a ser os da versão nova; um comando novo responde
      "reinicie o serviço para usar isto".
  ( ) Atualizar e reiniciar o serviço — fecha os 3 terminais.
      Agentes voltam pelo resume.
                       [Cancelar]  [Instalar ao sair]  [Instalar e reabrir]
  ```

  - Sem terminais abertos: sem opções, só "O Collie vai fechar e reabrir".
  - Com agente ocupado e a opção reiniciar: o botão vira **Esperar e instalar** (checa a cada 5 s, "esperando
    collie-dx…", Cancelar).
  - **Instalar ao sair**: a irmã é preparada e conferida **na hora do clique**; na saída
    (`willTerminateNotification`) só roda `renamex_np` + a conferência pós-troca. Nunca reinicia o serviço e não
    relança.
  - Pin de motor novo: a folha diz "O desenho fica indisponível até baixar o motor 0.8.0 (51 MB) depois de
    reiniciar o serviço" (§5).
- **Depois de reabrir**: "Atualizado para 0.2.0" uma vez. Com "só o app", o banner de serviço desatualizado
  existente aparece como sempre. Com motor novo e serviço reiniciado: o aviso traz **Baixar motor agora** (chama o
  `design.engine.install` existente).
- **Sem passo de "salvar estado"**: não existe comando para isso e não é preciso; os terminais e o workspace são do
  daemon, e o reinício do serviço já é o caminho de sempre (resume).

### 4. Mecânica de instalação

Divisão: **daemon** checa, baixa, confere sha256 e o dmg (tem o `fetch`, fica vivo com o app fechado); **app**
monta, copia, confere o `.app`, troca e relança (está na frente do usuário, então um pedido de TCC aparece para
ele; o `collied` do launchd sem interface poderia travar num pedido de "Volumes removíveis" ao montar,
<https://eclecticlight.co/2025/02/24/gaining-access-to-privacy-protected-folders/>,
<https://developer.apple.com/forums/thread/686498>).

1. **Daemon** (`UpdateChecker`, actor no molde do `FigcraftInstaller`), comandos `adminOnly`:
   `app.update.status` → `{state: none|available|ready|failed|disabled, available?:{version,size,page,
   figcraftEngine,figcraftSize?}, job?, lastCheck?, error?}`, `app.update.check`, `app.update.download`,
   `app.update.cancel`, `app.update.skip`. Fases: `downloading → verifying → ready`. Em `verifying`: sha256 →
   assinatura notarizada do dmg. `ready` deixa `<root>/.update-staging/Collie-<v>.dmg` (0700; `<root>` é negado
   aos terminais).
2. **App**, ao confirmar:
   1. Resolve o destino `Bundle.main.bundleURL`. Fallback (abrir `page`) se: caminho com `/AppTranslocation/`;
      volume só leitura; pasta-mãe sem escrita (`access(W_OK)`); `Config.tccWarning` não nil; build local (§2).
      Mensagem: "Mova o Collie para /Applications para atualizar por aqui" com **Baixar o dmg**.
   2. Espaço livre: `size` × 3 + 100 MB em `<root>` (o daemon confere antes de baixar) e em `size` × 3 na
      pasta-mãe do app (o app confere antes de montar).
   3. `hdiutil attach -nobrowse -readonly -noautoopen -mountrandom <tmp do app> <dmg>` → `mkdtemp` da irmã →
      `ditto` do `Collie.app` para `<irmã>/Collie.app` → `hdiutil detach` → `Info.plist` (versão = manifesto,
      `LSMinimumSystemVersion` ≤ sistema) → `signedByTeam` com aninhados → `stripQuarantine`. Symlinks: um `.app`
      pode ter symlinks relativos de framework; aceitar só os relativos que resolvem dentro do bundle, recusar
      setuid/setgid.
   4. Se escolheu reiniciar, espera agentes ocupados (§3).
   5. `renamex_np(<irmã>/Collie.app, Bundle.main.bundleURL, RENAME_SWAP)`; o antigo fica em `<irmã>/Collie.app`.
      **Nunca** escrever por cima de um arquivo do bundle em uso (gatilho 3 do estado atual).
   6. Conferência pós-troca no caminho final (§2 regra 3); falhou, destroca e aborta.
   7. Se escolheu reiniciar: `DaemonLauncher.restart` (`kickstart -k`).
   8. Grava em `UserDefaults` `{previous: "<irmã>/Collie.app", previousVersion, launches: 0}`, lança o relançador e
      sai: `/bin/sh -c 'while kill -0 <pid>; do sleep 0.2; done; /usr/bin/open <bundle>'` destacado
      (`posix_spawn` com `POSIX_SPAWN_SETSID`), e `NSApp.terminate`.
   - Falha em 1–6: nada trocado (ou destrocado), irmã apagada.
3. **Versão anterior guardada**: o app novo só apaga a irmã com o bundle antigo na **segunda** abertura em que
   conectou ao daemon (e, se o serviço foi reiniciado, com o `BuildID` do daemon igual ao do bundle). Até lá, a
   página mostra **Voltar para 0.1.0** (mesma troca por rename, ao contrário, com a mesma conferência de assinatura;
   o reinício do serviço segue a mesma folha). Se o app novo nem abre, o bundle antigo está na pasta oculta
   `.Collie-update-*` ao lado; `docs/` explica como trazê-lo de volta pelo Terminal.
- **Gatekeeper e quarentena**: `URLSession` não põe `com.apple.quarantine`; montar dmg sem quarentena gera cópia
  sem quarentena; `stripQuarantine` garante. Sem quarentena, sem avaliação de primeira abertura e sem translocation:
  a barreira é a assinatura do time no dmg (notarizado) e no `.app`.
- **App Management** (macOS 13+): o macOS deixa um app modificar outro do **mesmo time**
  (<https://developer.apple.com/documentation/bundleresources/information-property-list/nsupdatesecuritypolicy>).
  EPERM: fallback com link para Ajustes › Privacidade › Gestão de apps.
- **TCC entre versões**: a identidade Developer ID (identificador + time) é estável, então as permissões do app e do
  `collied` se mantêm de uma versão para a outra.
- **Daemon antigo + app novo ("só o app")** — contrato de compatibilidade, de uma versão `X.Y` para a seguinte:
  - O app novo trata `unknown command` (e campo ausente na resposta) como "reinicie o serviço para usar isto",
    nunca trava.
  - O `collie` novo (CLI, hooks `hook <nome>`, `statusLine`, notify, MCP) contra um daemon antigo: subcomandos de
    hook nunca são removidos nem renomeados sem passar uma versão; ferramenta MCP que o daemon não conhece responde
    erro com "reinicie o serviço"; o MCP não falha ao listar.
  - A linha de comando do `collie-ctty` (`--sandbox <perfil>` + comando) é estável; flag nova só opcional.
  - Recursos do bundle lidos pelo daemon antigo (`weblibs`, `Fonts`, `scrcpy-server`) passam a ser os novos: só
    mudanças aditivas.
  - Se uma versão precisar quebrar isso, o manifesto ganha `requiresServiceRestart: true` e a folha esconde "só o
    app" (campo opcional, só quando precisar).
- **Checador no daemon**: quem atualizar à mão e deixar rodando um daemon de antes do atualizador fica sem
  checagem até reiniciar o serviço; a página diz "reinicie o serviço para procurar atualizações" (o
  `app.update.status` responde `unknown command`).

### 5. Motor figcraft, Preferências, backup/import

- **Pin novo**: o manifesto traz `figcraftEngine`. Se difere do motor instalado (`design.engine.status`), a folha e
  o cartão dizem que **o desenho fica indisponível** até baixar o motor novo, e que isso vale depois de reiniciar o
  serviço (o daemon antigo segue com o pin antigo, `CommandRouter.swift:186`). Depois do reinício, o aviso
  "Atualizado" traz **Baixar motor agora**. Nada é baixado sozinho.
- **Pin igual**: `<root>/figcraft` não é tocado; continua `installed`.
- **Ocupado**: um sinal novo `maintenance` no daemon (backup, import, troca do motor, verificação do atualizador)
  substitui o uso de `figcraft.isHeld` como "ocupado" para o atualizador; `app.update.download` e a instalação
  recusam com `conflict` enquanto ele está ativo, e vice-versa. A atualização nunca toca `<root>` além do staging.

### 6. CI (`release.yml`, não nesta tarefa)

- **Draft órfão**: antes de criar, apagar drafts com a mesma tag (o laço de `figcraft.yml:78-83`); só uma release
  publicada leva `upload --clobber`.
- **Latest**: `--latest=false` quando a tag não é a maior `vX.Y.Z` entre as releases publicadas.
- **Manifesto**: depois dos `.sha256`, escrever `build/update.json` com `version`, `tag`, `dmg`, `size`
  (`stat -f %z`), `sha256`, `minimumSystemVersion` (do `Info.plist` do app gerado), `teamId` (de `codesign -dv` do
  app gerado, `TeamIdentifier=`), `figcraftEngine` (`version` do pin) e `page`. Subir junto com os quatro assets.
- **Checagem pós-publicação**: baixar `…/releases/download/<tag>/update.json` (nunca `latest`, que numa rodada de
  tag antiga aponta para outra) e conferir `sha256`/`size` contra o dmg publicado.
- Nada muda em `Collie.dmg`, notarização, pin, secrets.
- Teste offline do gerador do manifesto como `scripts/ci/test-update-pin.sh`.

### 7. Privacidade

- A checagem é um GET a `github.com/ysraelmoreno/collie/releases/latest/download/update.json`, sessão efêmera sem
  cache, `User-Agent: Collie/<versão>` e nenhum outro cabeçalho próprio: sem ID de instalação, e-mail, nome de
  máquina, contagem de uso. O GitHub vê o IP.
- Offline/erro: silencioso; a página mostra "sem conexão" e a última checagem boa. Erro só aparece em **Procurar
  agora**.
- Proxy: `URLSession` usa o proxy do sistema.
- Desligar a checagem automática zera o tráfego do atualizador.

### 8. Testes e validação

- Só `swift test --filter`, sem rede: `fetch`, assinatura e `hdiutil` injetáveis.
- **Unitários**: manifesto (estrito, coerência, versões, downgrade); `fetch` com limite de bytes e User-Agent (num
  `URLProtocol` de teste, sem rede); lista de recusados (sha divergente entra; 404/rede/cancelamento não);
  checador (fases, `maintenance` → `conflict`, staging limpo); `allowed` com os prefixos novos; perfil do sandbox
  com o deny `\.Collie-update-`; troca com dois `.app` de teste em diretório temporário (irmã exclusiva,
  `mkdtemp` recusa caminho existente, troca, conferência pós-troca que falha → destroca, apagar só na segunda
  abertura, voltar para a anterior, fallbacks de destino); compatibilidade (CLI novo com router sem um comando →
  mensagem "reinicie o serviço"; MCP lista sem falhar; `collie-ctty` aceita a linha antiga).
- **Override de fonte para teste**: `COLLIE_UPDATE_MANIFEST=file:///…` lido pelo **daemon** em qualquer build,
  só `file://`, logado e mostrado na página ("fonte de teste: …"). Não reduz a segurança: o dmg continua tendo de
  ser do time e notarizado (ou, em teste, do time, ver roteiro). Sem isso não há como validar com um app de
  release, porque `COLLIE_ROOT`/`COLLIE_LABEL` são só DEBUG e um app de release roda sempre com o label e o root
  reais.
- **Roteiro manual do dono** (nunca na conta do dono, para não tocar no daemon real): numa **conta de usuário
  macOS separada** (outro domínio `gui/<uid>`, outro `~/Library`, outro LaunchAgent):
  1. Dois dmgs de teste: `COLLIE_SKIP_NOTARIZE=1 COLLIE_VERSION=0.90.0 scripts/release.sh` e o mesmo com `0.90.1`
     (Developer ID, sem notarizar). Sem notarização o requisito `notarized` falha: o roteiro usa a 0.90.1 para
     provar a **recusa**, e uma release real de patch (passo 6) para o caminho feliz completo.
  2. Instalar a 0.90.0 em `~/Applications` da conta de teste; `launchctl setenv COLLIE_UPDATE_MANIFEST file:///…`
     e reiniciar o serviço da conta de teste.
  3. Conferir: download, recusa do dmg sem notarização, mensagem e lista de recusados.
  4. Conferir à mão o que teste unitário não cobre: `hdiutil attach` pelo app (pedido de TCC de Volumes
     removíveis?, `log stream --predicate 'subsystem == "com.apple.TCC"'`); se o Seatbelt nega a um terminal criar
     `~/Applications/.Collie-update-x` e `/Applications/.Collie-update-x`; App Management; troca real e
     relançamento via LaunchServices; "só o app" com um agente rodando (hooks novos contra o daemon antigo).
  5. Repetir 3–4 com `/Applications` (conta de teste admin) se o dono quiser cobrir o caminho padrão.
  6. Caminho feliz real: duas releases de patch publicadas (a primeira com atualizador e a seguinte), na conta de
     teste.

## Decisões

- Atualizador próprio (B); fallback "só avisar" (C).
- Manifesto `update.json` como asset no link `releases/latest/download`; URL do dmg derivada da tag.
- Instala do dmg existente; troca **só por rename**.
- Sem EdDSA; garantia = sha256 + dmg do time notarizado + `.app` do time (constante no app) + versão do bundle.
- Daemon checa, baixa e confere o dmg; app monta, copia, confere, troca e relança.
- Irmã exclusiva + deny no sandbox + conferência pós-troca com destroca.
- Atualizar o app e reiniciar o serviço são passos separados, com contrato de compatibilidade de uma versão.
- Versão anterior guardada até a segunda abertura saudável; voltar é ação explícita.
- Build local não se atualiza.
- `maintenance` como sinal de ocupado do daemon.
- Override `COLLIE_UPDATE_MANIFEST` só `file://`, em qualquer build; validação manual em outra conta macOS.

## Minhas chamadas (conferir)

1. **Intervalo**: 60 s após abrir e a cada 12 h. Poderia ser 24 h.
2. **Padrões**: checagem e download em segundo plano **ligados** (~42 MB sem perguntar).
3. **Opção padrão na folha** com terminais abertos: "Atualizar só o app". Alternativa: padrão reiniciar, para não
   deixar o serviço antigo rodando com hooks novos.
4. **Sem EdDSA**: quem tiver o `.p12` (CI) pode publicar atualização. Com uma chave fora do CI, a release passaria
   a esperar uma assinatura feita localmente.
5. **Página própria "Atualizações"** no grupo Interface.
6. **Notificação do sistema** uma vez por versão pronta (pode ser só o selo).
7. **"Instalar ao sair"** existe, não reinicia o serviço e não relança.
8. **"Esperar e instalar"** espera sem limite de tempo (até Cancelar).
9. **"Voltar para a versão anterior"** como botão na página (em vez de só instruções em `docs/`).
10. **Validação em outra conta macOS** do Mac do dono (alternativa: outro Mac).

## Tarefas (resumo; o plano detalha)

1. Manifesto. 2. `fetch` com limite e cabeçalhos. 3. `allowed`. 4. Checador no daemon. 5. Comandos `app.update.*`.
6. Deny `\.Collie-update-` no sandbox. 7. Verificação do `.app` e troca no app. 8. Compatibilidade CLI/ctty/app.
9. Página e folha. 10. Motor. 11. CI (**passo do dono**: revisar e mergear). 12. Roteiro manual (**passo do dono**).
