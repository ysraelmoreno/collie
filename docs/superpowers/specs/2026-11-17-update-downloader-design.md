# Atualizador automático do Collie — design

Status: rascunho para o dono revisar (2026-11-17). Nada implementado. Sem plano ainda.

## Intenção e porquê

Hoje cada versão nova do Collie exige ir ao site ou ao GitHub, baixar o `Collie.dmg`, arrastar para
`/Applications` e reabrir. O dono quer que o app descubra sozinho que há versão nova, baixe em segundo plano, confira
e instale com um clique, **sem derrubar sem aviso os terminais e agentes que estão rodando**. O Collie não está na
App Store, então não há atualizador do sistema: é preciso um próprio ou uma biblioteca.

O que tornaria isto um fracasso mesmo funcionando: instalar e fechar agentes no meio do trabalho; aceitar um app que
não é do time AG8JQAH6YB; tratar a release do motor `figcraft-v*` como versão do app; um laço de downloads que
falham sem fim; mandar qualquer identificador do usuário para fora.

## Estado atual (verificado no código, main em 0fb2323)

- **Release**: `.github/workflows/release.yml` roda em tag `vX.Y.Z` (ou manual com tag existente), chama
  `scripts/release.sh` e cria a GitHub Release com `Collie-<v>.dmg`, `Collie-<v>.dmg.sha256` e as cópias idênticas
  `Collie.dmg`/`Collie.dmg.sha256` (link estável `releases/latest/download/Collie.dmg`). Release já existente: só
  `gh release upload --clobber` (os bytes do dmg mudam: a notarização não é reproduzível). Notas: um texto fixo +
  `--generate-notes`. Não há draft nesse fluxo.
- **Assinatura**: `release.sh` assina o app (hardened runtime, `--timestamp`), confere cada Mach-O, cria o dmg UDZO,
  assina o dmg, notariza **o dmg** e grampeia **só o dmg** (`stapler staple "$DMG"`). O `.app` dentro do dmg não tem
  ticket próprio grampeado; o ticket da Apple cobre o conteúdo, consultável online.
- **Motor**: `figcraft.yml` publica `figcraft-v<versão>` com `--prerelease --latest=false`; `/releases/latest` e
  `/releases/latest/download/...` nunca apontam para ele. O pin `Resources/figcraft-engine.json` vai para
  `Contents/Resources/` do app.
- **Versão**: `CFBundleShortVersionString` (`Resources/Info.plist`, hoje `0.1.0`; o CI sobrescreve com a tag).
  `DaemonConfig.bundleVersion(executable:)` (`Daemon.swift:130`) lê o `Info.plist` do bundle **do disco** a cada
  chamada.
- **Daemon**: `DaemonLauncher` (`Sources/CollieClient/DaemonLauncher.swift`) instala o LaunchAgent
  `dev.collie.daemon` (`KeepAlive`, `RunAtLoad`) apontando para `<app>/Contents/Helpers/collied`.
  `ensureRunning` só reescreve e reinicia se o plist mudar; o caminho é o mesmo depois de trocar o app em
  `/Applications`, então **trocar o .app não reinicia o daemon**. O processo antigo segue rodando (o inode antigo
  fica aberto) até alguém reiniciar.
- **Banner de serviço desatualizado**: o app compara o `BuildID` do `collied` empacotado com o do daemon conectado
  (`CollieApp.swift:198`) e mostra "O serviço do Collie está desatualizado… Os terminais abertos serão encerrados"
  com **Reiniciar serviço** (`DaemonLauncher.restart` = `kickstart -k`) e **Depois** (`CollieApp.swift:212-227`). É
  esse reinício que fecha os terminais (a memória do projeto chama isso de "instalar reinicia o daemon": o efeito
  vem do reinício, não da cópia).
- **Admin**: `SignedAppCheck` (`AdminPeerCheck.swift`) aceita só o app cujo cdhash bate com o
  `Contents/MacOS/Collie` em disco ao lado do `collied`; relê o arquivo quando muda (dev, inode, mtime, size). Depois
  de uma troca, a instância antiga do app passa a ser recusada; a nova é aceita até pelo daemon antigo.
- **Helpers**: `TerminalRegistry.spawn` confere `collie-ctty` a cada spawn ("an app update can replace Helpers/
  under a running daemon"), ou seja, o código já prevê daemon antigo com bundle novo. Não há número de versão de
  protocolo no handshake do `DaemonClient`: o app novo com daemon antigo só funciona porque o protocolo é aditivo.
- **Local do app**: `Config.tccWarning` (`CollieApp.swift:29`) avisa quando o app está em `~/Documents`, `~/Desktop`
  ou `~/Downloads`. Nada trata App Translocation.
- **Moldes de download**: `AndroidDownload.fetch` (sessão efêmera, sem cookies/cache, todo redirect e a URL final
  checados por `allowed`: https, host da lista, porta padrão, sem credenciais; em `github.com` só `/adoptium/` e
  `/ysraelmoreno/collie/releases/download/figcraft-v`), `AndroidDownload.verify` (sha256), `FigcraftInstaller`
  (actor com `Job{phase,bytes,total,error}`, staging 0700, sha256 antes de extrair e sem retentar, `scan` sem
  symlink/setuid, `signedByTeam` = Developer ID Application do team com identificador, `kSecCSStrictValidate |
  kSecCSCheckAllArchitectures`, `stripQuarantine`, troca com `renamex_np(RENAME_SWAP)`). Comandos do motor ficam
  `adminOnly` e o app faz poll (`DesignEngineModel.swift`, estado `needsUpdate`).
- **Preferências**: `PreferencePage` = `aparencia, terminal, desenho, memoria, plugins, celular, android`, em grupos
  Interface / Agentes / Dispositivos. Não há página de atualizações.
- **Backup/import**: `DataBackup` grava `collieVersion` no manifesto; o import de dados pede confirmação e reinicia o
  serviço (`CollieApp.swift:465-480`), o mesmo padrão de confirmação que este design reusa.
- **Dependências**: SwiftPM só com SwiftTerm `exact: "1.99.0"`.

## Metas

1. Descobrir versão nova sozinho (na abertura e periodicamente) e avisar sem atrapalhar.
2. Baixar em segundo plano e verificar: sha256, assinatura Developer ID do team AG8JQAH6YB, versão maior que a
   instalada.
3. Instalar com um clique, trocando o `.app` de forma atômica e reabrindo.
4. Nunca fechar terminais sem confirmação que diga quantos e quais estão ativos; permitir atualizar o app **sem**
   reiniciar o serviço.
5. Avisar quando a versão nova traz pin de motor de design novo.
6. Zero identificadores na checagem; funcionar calado offline.

## Não metas

- Atualização delta, canal beta, rollout em fases.
- Instalar quando o usuário não tem permissão de escrita na pasta do app (pedir senha de admin): nesse caso o app
  abre a página da release. Fica para depois se alguém pedir.
- Atualizar o motor figcraft junto (continua no fluxo próprio das Preferências).
- Rebaixar versão (downgrade) por qualquer caminho automático.
- Intel / Rosetta (o app é arm64 só).

## Abordagens

### A. Sparkle 2

Fonte: documentação pública em <https://sparkle-project.org/documentation/> (seções *Publishing an update*, *EdDSA
signatures*, *Sandboxing*, *Customization*). Citado de leitura anterior desta documentação, não buscada nesta sessão:
conferir antes de citar números.

- **Como é**: framework (SwiftPM `https://github.com/sparkle-project/Sparkle`), `SUFeedURL` com um appcast RSS
  (pode morar em GitHub Pages ou como asset), `SUPublicEDKey` no `Info.plist`, `generate_keys` cria a chave Ed25519 no
  keychain de quem publica, `sign_update`/`generate_appcast` assinam o arquivo. Aceita zip, dmg e pkg. Para app **não
  sandboxed** (o caso do Collie) não precisa dos serviços XPC; o instalador é o helper `Autoupdate` embutido no
  framework, que espera o app sair, troca o bundle e relança. Confere EdDSA e também que o app novo tem a mesma
  assinatura de código do antigo.
- **UX**: janela própria com notas (HTML do appcast), "Pular esta versão", "Lembrar depois", checagem automática
  configurável, *gentle reminders*. Delegate `SPUUpdaterDelegate` permite adiar (`updater(_:willInstallUpdateOnQuit:
  immediateInstallationBlock:)`) e decidir o relançamento.
- **Daemon launchd**: o Sparkle não sabe dele. Quem cuida de avisar dos terminais e de reiniciar (ou não) o
  `collied` seria o delegate, do mesmo jeito que num atualizador próprio.
- **Custo**: dependência nova (framework + helpers que `bundle-app.sh`/`release.sh` precisam embutir e assinar com
  hardened runtime e timestamp; o laço de `release.sh` que confere cada Mach-O passa a cobri-los); segundo segredo de
  assinatura (chave EdDSA) no CI; appcast novo; UI em inglês com tradução pt-BR do projeto, visualmente fora do
  padrão das Preferências do Collie; o fluxo crítico (terminais) fica dividido entre o delegate e a janela do Sparkle.
- **Ganho real**: código maduro e auditado de troca/relançamento, atualização com senha de admin, delta.

### B. Atualizador próprio no molde do `FigcraftInstaller` (recomendada)

- Manifesto `update.json` como asset de cada release do app, lido pelo link estável
  `https://github.com/ysraelmoreno/collie/releases/latest/download/update.json` (sem API, sem limite de taxa, já
  ignora prerelease e draft).
- Download do `Collie-<v>.dmg` (o mesmo que o usuário baixaria), sha256 do manifesto, montagem somente leitura,
  `signedByTeam` no `.app` de dentro (identificador `dev.collie.app`), versão do `Info.plist` de dentro conferida,
  troca atômica do bundle, relançamento, e reinício do daemon **separado e opcional**.
- **Custo**: ~uma tela de Preferências, um actor no daemon e uma rotina de troca no app; quase tudo reaproveita
  `AndroidDownload.fetch/verify`, `FigcraftInstaller.signedByTeam/stripQuarantine/scan`, o padrão `Job` + poll e o
  padrão de confirmação do import. Sem dependência nova, sem segredo novo.
- **Perde**: delta, instalação com senha de admin, a maturidade do Sparkle no relançamento (cobrimos com testes de
  troca e um relançador mínimo).

### C. Só avisar (sem instalar)

Checar o manifesto e mostrar "Collie X disponível — Baixar" abrindo `Collie.dmg`. Barato, mas não resolve o pedido
(o usuário ainda arrasta e reabre). Vira o **fallback** de B quando não dá para instalar no lugar.

**Recomendação: B.** O pedaço difícil (não derrubar terminais, daemon launchd, figcraft) é igual nas duas; o Sparkle
não o resolve e cobra dependência, segundo segredo, embutir/assinar helpers e UI fora do padrão. O resto do B já
existe no código. A assinatura Developer ID por team é a mesma garantia que o motor figcraft já usa.

## Design

### 1. Fonte da verdade e canal

- **Manifesto** `update.json` (asset de cada release `vX.Y.Z`, gerado pelo CI):

  ```json
  {
    "format": 1,
    "version": "0.2.0",
    "tag": "v0.2.0",
    "dmg": "Collie-0.2.0.dmg",
    "size": 42123456,
    "sha256": "<64 hex do dmg>",
    "minimumSystemVersion": "15.0",
    "teamId": "AG8JQAH6YB",
    "figcraftEngine": "0.7.0-c1",
    "notes": "<texto curto em Markdown, até 4 KB>",
    "page": "https://github.com/ysraelmoreno/collie/releases/tag/v0.2.0"
  }
  ```

  A URL do dmg **não** vem do manifesto: o cliente monta
  `https://github.com/ysraelmoreno/collie/releases/download/<tag>/<dmg>` e recusa `tag` fora de `^v\d+\.\d+\.\d+$`,
  `dmg` diferente de `Collie-<version>.dmg` e `tag` diferente de `v<version>`. Assim um manifesto adulterado não
  aponta para outro lugar.
- **Por que manifesto e não a API**: `api.github.com/repos/.../releases/latest` sem token tem limite de 60
  pedidos/hora por IP (rede compartilhada esgota) e devolve JSON grande. O link `releases/latest/download/<asset>` é
  um redirect sem limite documentado e já tem a semântica certa: release publicada, não draft, não prerelease, a
  marcada como latest. `figcraft-v*` é prerelease com `--latest=false`: nunca entra.
- **dmg, não zip**: é o artefato que já existe, notarizado e grampeado; um zip exigiria segunda notarização (o app
  não é grampeado sozinho) ou um zip sem ticket. Montar dmg custa um `hdiutil attach` (ver §4).
- **Ordem de versões**: `X.Y.Z` comparado como três inteiros. Oferece só se `manifesto.version > instalada`. A
  instalada vem de `Bundle.main` (`CFBundleShortVersionString`), não do daemon (que lê do disco).
- **Downgrade**: recusado em dois pontos: o manifesto (`version > instalada`) e o `Info.plist` **de dentro do dmg**
  (tem que ser igual a `manifesto.version`). Um dmg antigo legítimo servido no lugar do novo falha no sha256 ou na
  versão.
- **Release trocada** (`--clobber` regera o dmg com bytes novos): o sha256 do manifesto e o dmg são lidos na mesma
  rodada; se o sha256 não bate, a rodada falha com "a release mudou durante o download" e **não** retenta na hora; a
  próxima checagem lê o manifesto novo. Registra o sha256 que falhou para não baixar o mesmo de novo em laço.
- **Manifesto ausente** (404, releases antigas sem `update.json`): "nada novo", sem erro visível.

### 2. Segurança

- **Hash**: sha256 do dmg inteiro antes de montar (`AndroidDownload.verify`). Falhou: apaga, não monta, não
  retenta.
- **Assinatura**: no `.app` copiado para o staging, `signedByTeam(app, "dev.collie.app", "AG8JQAH6YB")` com
  `kSecCSStrictValidate | kSecCSCheckAllArchitectures`, mais `kSecCSCheckNestedCode` para cobrir `Helpers/collied`,
  `collie`, `collie-ctty` (a variante com aninhados é uma flag a mais na mesma função; os binários de Helpers também
  são conferidos um a um com seus identificadores, como o motor). O team ID esperado é **constante do app**, não do
  manifesto (o campo `teamId` do manifesto só precisa bater).
- **Notarização**: o dmg é grampeado; o app novo é verificado com `spctl --assess --type execute` (avaliação do
  Gatekeeper, online se preciso) antes da troca. Falha de rede nessa avaliação: aceita se a assinatura do team passou
  (o Gatekeeper nem é consultado num app sem quarentena; ver §4), e registra.
- **Quem pode publicar**: só o CI com os secrets do Developer ID (`DEVELOPER_ID_P12_*`) produz um app que passa. Quem
  tem push de tag no repo dispara o CI; hoje é só o dono.
- **EdDSA**: não. Uma chave EdDSA no mesmo CI protege contra o mesmo atacante que já teria o `.p12`; só agregaria se
  ficasse **fora** do CI (assinatura local), o que quebra o fluxo de release por tag. Ver "Minhas chamadas".
- **Hosts**: `AndroidDownload.allowed` ganha, em `github.com`, os prefixos `/ysraelmoreno/collie/releases/latest/download/`
  e `/ysraelmoreno/collie/releases/download/v` (o `v` não casa com `figcraft-v`, que já tem o seu). Redirects para
  `objects.githubusercontent.com` / `release-assets.githubusercontent.com` já estão na lista. Manifesto limitado a
  64 KB e decodificado estrito (campo faltando = recusa).
- **Falha de verificação**: estado `failed` com a frase do motivo nas Preferências, staging apagado, nada tocado em
  `/Applications`, nenhum retry automático para o mesmo sha256.
- **Staging**: `<root>/.update-staging` (0700). Os terminais são sandboxed e só escrevem no projeto, então um agente
  não troca o app verificado entre a checagem e a cópia; mesmo assim a assinatura é conferida de novo na cópia final,
  já ao lado do app (§4).

### 3. UX

- **Checagem**: 60 s depois de abrir e a cada 12 h enquanto aberto (laço como o do resumo diário). Botão
  **Procurar agora** nas Preferências.
- **Página nova** `PreferencePage.atualizacoes`, título **"Atualizações"**, grupo **Interface**, ícone `↻`:
  - "Versão instalada 0.1.0 · última verificação há 2 h" (ou "sem conexão").
  - Interruptores: **Procurar atualizações automaticamente** (ligado) e **Baixar em segundo plano** (ligado).
  - Com versão nova: cartão "Collie 0.2.0 disponível · 42 MB", as `notes` (Markdown simples), link "Ver no GitHub"
    (`page`), botões **Instalar…**, **Pular esta versão**, progresso de download.
  - Selo na barra lateral da página, como o selo do Android.
- **Aviso discreto**: um ponto no ícone de Preferências/menu e, só uma vez por versão, uma notificação do sistema
  (`Notifier`) "Collie 0.2.0 pronto para instalar". Nada de janela modal ao abrir.
- **Pular esta versão**: guarda a versão em `UserDefaults`; some até sair uma maior.
- **Download em segundo plano**: com o interruptor ligado, baixa e verifica logo que acha; fica pronto no staging.
  Desligado: baixa quando o usuário clica **Instalar…**.
- **Instalar… (ponto crítico)**: abre uma folha de confirmação que lista o estado atual, pedido ao daemon
  (`list`/registro de terminais):

  ```
  Instalar Collie 0.2.0
  Há 3 terminais abertos (2 agentes trabalhando agora: collie-dx, apps-dev).

  ( ) Atualizar só o app — os terminais continuam rodando.
      O serviço antigo segue até você reiniciá-lo (o aviso de serviço
      desatualizado aparece no app novo).
  ( ) Atualizar e reiniciar o serviço — fecha os 3 terminais.
      Agentes voltam pelo resume.
                                   [Cancelar]  [Instalar e reabrir]
  ```

  - Sem terminais abertos: a folha não tem opções, só "O Collie vai fechar e reabrir".
  - Com agente ocupado, a opção "reiniciar o serviço" mostra quem está ocupado e o botão fica **Esperar e instalar**:
    o app espera até nenhum agente estar ocupado (checa a cada 5 s, mostra "esperando collie-dx…" com Cancelar) e só
    então instala. "Ocupado" usa o mesmo sinal do `targetBusy` do `ask`.
  - **Instalar ao sair**: botão secundário; marca a instalação para quando o usuário fechar o app (sempre "só o app":
    nunca reinicia o serviço sem estar na frente do usuário).
- **Salvar estado**: antes de trocar, o app pede ao daemon que grave o workspace (o mesmo caminho do encerramento
  normal); os terminais são do daemon, não do app, então "só o app" não perde nada.
- **Depois de reabrir**: o app novo mostra "Atualizado para 0.2.0" uma vez. Se o usuário escolheu "só o app", o
  banner existente de serviço desatualizado aparece com o texto de sempre. Se escolheu reiniciar, o reinício já foi
  feito antes de reabrir.

### 4. Mecânica de instalação

Divisão: **daemon** checa, baixa, verifica e prepara (tem o `fetch`, o padrão de `Job` e fica vivo); **app** faz a
troca e o relançamento (é ele que sai, e é o processo do usuário na frente).

1. **Daemon** (`UpdateInstaller`, actor no molde do `FigcraftInstaller`), comandos `adminOnly`:
   `app.update.check` → `{state: none|available|ready|failed, available?:{version,size,notes,page,figcraftEngine}, job?}`,
   `app.update.download`, `app.update.cancel`, `app.update.status`. Fases: `downloading → verifying → ready`.
   Em `verifying`: sha256 → `hdiutil attach -nobrowse -readonly -noautoopen -mountrandom <staging>` →
   `ditto` do `Collie.app` para `<staging>/Collie.app` → `hdiutil detach` → `scan` (sem symlink fora do bundle; o
   `scan` do motor recusa todo symlink e um `.app` tem symlinks em `Frameworks` se um dia houver: aceitar só symlinks
   relativos que resolvem dentro do bundle) → `signedByTeam` (app + Helpers) → `Info.plist` versão e
   `LSMinimumSystemVersion` ≤ sistema → `stripQuarantine`. Espaço livre: `size` × 3 + margem.
2. **App**, ao confirmar:
   1. Resolve o destino: `Bundle.main.bundleURL`. Recusa e cai no fallback (abrir `page`) se: o caminho tem
      `/AppTranslocation/`; está num volume somente leitura (rodando do dmg); a pasta-mãe não é gravável
      (`access(W_OK)`); `Config.tccWarning` não é nil. Mensagem: "Mova o Collie para /Applications para atualizar
      por aqui" com **Baixar o dmg**.
   2. `ditto` do staging para uma irmã `<pasta-mãe>/.Collie-<v>.app.update` (mesmo volume: `renamex_np` exige; o
      staging do daemon pode estar em outro volume se o app estiver fora do disco principal). Confere
      `signedByTeam` de novo nessa cópia.
   3. Grava o workspace, e se escolheu reiniciar o serviço, ainda não reinicia.
   4. `renamex_np(irmã, Bundle.main.bundleURL, RENAME_SWAP)`: o app novo ocupa o nome; o antigo vai para a irmã. O
      processo em execução continua com seus arquivos abertos; daqui em diante o app atual não carrega nada novo do
      bundle (troca é o último passo antes de sair).
   5. Se escolheu reiniciar: `DaemonLauncher.restart` (`kickstart -k`): o launchd sobe o `Helpers/collied` do
      bundle novo, mesmo caminho, mesmo plist.
   6. Lança o relançador e sai: `/bin/sh -c 'while kill -0 <pid>; do sleep 0.2; done; /usr/bin/open <bundle>'`
      destacado (`posix_spawn` com `setsid`), e `NSApp.terminate`.
   7. O app novo, na abertura, apaga `.Collie-*.app.update` irmãos (o antigo) e o staging.
   - Falha em 2–4: nada trocado (a irmã é apagada); falha depois de 4 e antes de 6: o app novo já está no lugar, o
     usuário reabre à mão. Rollback não é preciso: a troca é atômica.
- **Gatekeeper e quarentena**: `URLSession` não põe `com.apple.quarantine`; o `hdiutil attach` de um arquivo sem
  quarentena gera cópia sem quarentena; `stripQuarantine` garante. Sem quarentena, o macOS não roda a avaliação de
  primeira abertura nem translocation. Por isso a assinatura por team (e o `spctl` do §2) é a barreira real.
- **App Management** (macOS 13+): o macOS deixa um app modificar outro assinado pelo **mesmo time**; o Collie troca
  a si mesmo, mesmo time. Se o macOS recusar (EPERM), cai no fallback com a mensagem e um link para Ajustes ›
  Privacidade › Gestão de apps.
- **Permissão de `/Applications`**: admin escreve; usuário padrão não. Não pedimos senha (não meta).
- **Admin depois da troca**: o `SignedAppCheck` do daemon (antigo ou novo) passa a aceitar o app novo e a recusar o
  antigo; como o antigo sai logo em seguida, não há janela de recusas visível.
- **Daemon antigo + app novo** ("só o app"): é o caso que o banner de serviço desatualizado já cobre. Risco: sem
  versão de protocolo no handshake, um comando novo do app chamado num daemon antigo recebe "unknown command". Regra
  para o builder: o app novo trata `unknown command` como "reinicie o serviço para usar isto" e nunca trava. Se uma
  versão um dia quebrar o protocolo de forma incompatível, o manifesto ganha `requiresServiceRestart: true` e a folha
  esconde a opção "só o app" (campo opcional, não implementar antes de precisar).

### 5. Motor figcraft, Preferências, backup/import

- **Pin novo**: o manifesto traz `figcraftEngine` (a `version` do pin daquela release). Se difere da versão do motor
  instalado, o cartão diz "Esta versão usa o motor de design 0.8.0: depois de atualizar, baixe-o em Preferências ›
  Desenho e sandbox". Nada é baixado sozinho. O estado `needsUpdate` existente aparece quando o **daemon novo**
  estiver rodando (o daemon antigo ainda lê o pin antigo); com "só o app", o aviso do motor só vale depois de
  reiniciar o serviço, e o cartão diz isso.
- **Pin igual**: o motor em `<root>/figcraft` é dado do usuário fora do bundle; trocar o app não o toca e o estado
  continua `installed`.
- **Preferências**: página nova "Atualizações" (§3); a página do motor não muda.
- **Backup/import e motor ocupados**: `app.update.download` e a instalação recusam com `conflict` enquanto há backup,
  import ou troca do motor (o mesmo `busy` do `FigcraftInstaller`), e vice-versa durante `verifying`. A atualização
  nunca toca `<root>`, só o staging. Um backup feito na versão nova importa na antiga? Não é deste design: o
  `collieVersion` do manifesto do backup já existe para essa regra.

### 6. CI (`release.yml`, sem mexer nesta tarefa)

- Depois de gerar os `.sha256`, um passo **Manifesto** escreve `build/update.json` com `jq`/`plutil`: `version`,
  `tag`, `dmg`, `size` (`stat -f %z`), `sha256`, `minimumSystemVersion` (do `Info.plist` do app gerado),
  `teamId` (do `Resources/figcraft-engine.json`, já é o do certificado), `figcraftEngine` (`version` do pin),
  `notes` (primeiras linhas das notas, até 4 KB) e `page`.
- Sobe junto com os quatro assets atuais, **por último** na lista (num `upload --clobber` a cópia do dmg precede o
  manifesto). Release recém-criada: conferir se `gh release create` com assets publica só depois de subir todos
  (se não, criar como draft, subir, publicar, como o `figcraft.yml` faz).
- Um passo de checagem baixa o `update.json` publicado e confere `sha256`/`size` contra o dmg publicado (molde do
  "Conferir motor").
- **Nada muda** em `Collie.dmg`, notarização, pin, secrets. Nenhum secret novo.
- Teste offline do gerador de manifesto como os de `scripts/ci/test-update-pin.sh`.

### 7. Privacidade

- A checagem é um GET a `github.com/ysraelmoreno/collie/releases/latest/download/update.json` com sessão efêmera
  (sem cookies, sem cache), `User-Agent: Collie/<versão>` e nada mais: sem ID de instalação, e-mail, nome de
  máquina, contagem de uso. O GitHub vê o IP, como em qualquer download do site.
- Offline/erro: silencioso; a página mostra "sem conexão" e a hora da última verificação boa. Erro só aparece em
  **Procurar agora**.
- Proxy: `URLSession` usa o proxy do sistema.
- Desligar "Procurar atualizações automaticamente" zera todo tráfego do atualizador.

### 8. Testes e validação

- Só `swift test --filter`, sem rede: `fetch` injetado (como `FigcraftInstallerTests`), `signature` injetada,
  `hdiutil` atrás de um runner injetável (`AndroidInstaller.run`).
- `UpdateManifestTests`: decodificação estrita, tamanho máximo, `tag`/`dmg`/`version` coerentes, comparação de
  versões, downgrade e versão igual recusados, `minimumSystemVersion`.
- `UpdateInstallerTests`: sha256 errado não monta e não retenta o mesmo sha; assinatura recusada; `Info.plist` com
  versão diferente; cancelamento; `busy` → `conflict`; staging limpo em todo caminho.
- `UpdateSwapTests`: dois `.app` de teste montados em diretório temporário (pastas com `Contents/Info.plist`):
  troca atômica, irmã apagada na abertura seguinte, destino translocado/só leitura/sem escrita cai no fallback.
- `AndroidDownloadTests`: os prefixos novos do `allowed` e que `figcraft-v` e outras rotas continuam como estão.
- Validar sem publicar release: build `DEBUG` aceita `COLLIE_UPDATE_MANIFEST=file:///…` (ignorado no release, como
  os overrides `COLLIE_ROOT`), com um dmg de `COLLIE_SKIP_NOTARIZE=1 scripts/release.sh` feito pelo dono (assinado
  com o Developer ID, sem notarizar); a versão maior via `COLLIE_VERSION`. Testa download, verificação, troca e
  relançamento num app copiado para uma pasta gravável fora de `/Applications` (ex.: `~/Applications`).
- Validação final com release real: só o dono, numa versão de patch.

## Decisões

- Atualizador próprio (B), não Sparkle; fallback de só avisar (C) quando não dá para instalar no lugar.
- Manifesto `update.json` como asset no link `releases/latest/download`, não API do GitHub nem appcast no Pages.
- Instala do dmg existente; sem zip.
- Sem EdDSA; a garantia é sha256 + Developer ID do team AG8JQAH6YB (constante no app) + versão dentro do bundle.
- Daemon baixa e verifica; app troca e relança.
- Atualizar o app e reiniciar o serviço são passos separados; reiniciar só com confirmação na frente do usuário.
- Sem senha de admin, sem delta, sem beta.

## Minhas chamadas (conferir)

1. **Intervalo**: 60 s após abrir e a cada 12 h. Poderia ser 24 h.
2. **Padrões**: checagem automática e download em segundo plano **ligados**. Download de ~42 MB sem perguntar pode
   incomodar em rede limitada.
3. **Opção padrão na folha** com terminais abertos: "Atualizar só o app" (os agentes seguem). Alternativa: padrão
   reiniciar, para não deixar serviço velho rodando.
4. **Sem EdDSA**: aceito que quem tiver o `.p12` (CI) pode publicar atualização. Se o dono quiser uma segunda chave
   fora do CI, o CI passa a esperar uma assinatura feita localmente antes de publicar.
5. **Página própria "Atualizações"** no grupo Interface, em vez de uma seção numa página existente.
6. **Notificação do sistema** uma vez por versão pronta. Pode ser só o selo.
7. **Instalar ao sair** existe e nunca reinicia o serviço.
8. **"Esperar e instalar"** espera agentes ocupados sem limite de tempo (até Cancelar).
9. `spctl` com falha de rede não bloqueia se a assinatura do team passou.

## Tarefas (independentes onde marcado)

1. `UpdateManifest` (modelo, decodificação estrita, comparação de versões) + testes. Independente.
2. Prefixos novos em `AndroidDownload.allowed` + testes. Independente.
3. `UpdateInstaller` no daemon (fetch, sha256, `hdiutil`, `scan` para bundle, assinatura com aninhados, `Info.plist`,
   quarentena, staging, `busy`) + testes. Depende de 1 e 2.
4. Comandos `app.update.*` em `Commands.swift`/router, `adminOnly`, + `CommandsTests` e `MCPTests` (armadilha do
   esquema ordenado). Depende de 3.
5. Troca e relançamento no app (`UpdateSwap`: destino, fallback, irmã, `renamex_np`, relançador, limpeza na
   abertura) + testes com `.app` de teste. Independente de 3/4 (só usa um caminho de staging).
6. Página "Atualizações" + folha de confirmação com terminais/ocupados + selo + notificação. Depende de 4 e 5.
7. Aviso do motor figcraft no cartão. Depende de 6.
8. Override `COLLIE_UPDATE_MANIFEST` só em DEBUG. Junto com 3.
9. `release.yml`: passo Manifesto + checagem pós-publicação + teste offline do gerador; atualizar `docs/release.md`.
   Independente do código do app. **Passo do dono**: revisar e mergear (mexe em `.github/`).
10. **Passo do dono**: dmg de teste com `COLLIE_SKIP_NOTARIZE=1 COLLIE_VERSION=<maior> scripts/release.sh` para a
    validação local; depois, uma release de patch real para validar ponta a ponta (a primeira versão com
    atualizador só consegue atualizar para a seguinte: quem está na 0.1.0 ainda baixa à mão uma vez).
11. **Passo do dono**: conferir se `gh release create` com assets publica antes de subir todos (ver §6).
