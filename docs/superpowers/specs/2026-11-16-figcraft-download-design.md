# Motor de design (figcraft) baixável — design

Status: rascunho para aprovação. Nada implementado.

## Intenção e porquê

O figcraft (motor do painel Design e dos comandos `collie design *`) ocupa 109 MB dos 206 MB do `Collie.app` e é o
passo mais lento do CI de release (Rust → wasm, 20 a 40 min a frio). Quem não usa design paga o download e o CI paga o
tempo a cada release do app, mesmo quando o figcraft não mudou. O dono quer o dmg do Collie **sem** o figcraft e o
motor como download separado, sob pedido, em Preferências ("Baixar motor de design", com progresso, remover e
atualizar). O motor é compilado e publicado por um workflow próprio, só quando o pin do figcraft muda.

## Estado atual (verificado no código)

- **Build**: `scripts/build-figcraft.sh` fixa figcraft `v0.7.0` (commit `47438dd4a2e8b49a7e6bb3dfd480262dadc37f12`),
  craft-fonts `43913056…`, Rust 1.99.1, trunk 0.22.0, wasm-bindgen 0.2.129, binaryen 131 (sha256 conferido), aplica
  `patches/figcraft/0001…0005` e gera `vendor/figcraft/{bin,web,licenses}`. Medido: `bin/` 87 MB (`figcraft-cli`
  76,6 MB, `figcraft-server` 10,9 MB), `web/` 22 MB (21 MB são o `.wasm`), `licenses/` 188 KB. Os binários só ligam a
  bibliotecas do sistema (`otool -L figcraft-server`: libSystem, libobjc, Foundation, libiconv).
- **Bundle**: `scripts/bundle-app.sh` copia `vendor/figcraft/{bin,web,licenses}` para `Contents/Resources/figcraft/`
  quando existe (senão só avisa) e assina cada binário com `--options runtime` (+ `--timestamp` no release); copia
  `Resources/NOTICE-figcraft` sempre. No `Collie.app` atual: `Resources/figcraft` 109 MB de 206 MB; `drawio` 34 MB.
- **dmg**: `Collie-0.1.0.dmg` = 98,6 MB (UDZO). `vendor/figcraft` em `tar.gz` = 51,4 MB.
- **CI**: `.github/workflows/release.yml` (tag `v*` ou manual, `macos-26`, timeout 330 min por causa do figcraft frio)
  guarda `vendor/figcraft` em `actions/cache` com chave `hashFiles('scripts/build-figcraft.sh','patches/figcraft/**')`
  e só compila sem cache; publica `Collie-<v>.dmg` e a cópia `Collie.dmg` para o link
  `releases/latest/download/Collie.dmg`.
- **Daemon**: `Sources/collied/main.swift:73` resolve `COLLIE_FIGCRAFT_DIR` ou `<Helpers>/../Resources/figcraft` e põe
  em `config.figcraftDir` (opcional). `CommandRouter.swift:178` cria `FigcraftServer(binary: <dir>/bin/figcraft-server,
  dataDir: <root>/design/server)` e `DesignService(figcraftDir:)` usa `<dir>/bin/figcraft-cli` (um `figcraft-cli mcp`
  por chamador). Ambos guardam o caminho em `let`, fixo na vida do daemon. Sem binário, `ensureRunning` lança
  `FigcraftServer.notBundled` ("Design engine not bundled (run scripts/build-figcraft.sh and rebuild)").
  `FigcraftServer.stop()` (TERM, KILL após 2 s) e `DesignService.stop()` (fecha todos os clientes) já existem; um
  servidor que morre volta sozinho e o painel reconecta; os arquivos de design ficam em `<root>/design/server`, fora do
  diretório do motor.
- **Painel**: `DesignPanel.webDirectory` (`static let`, calculado uma vez) procura `Bundle.main/figcraft/web`, depois
  `COLLIE_FIGCRAFT_DIR/web`, depois (DEBUG) `vendor/figcraft/web`. Sem ele: "Motor de design indisponível / Rode
  scripts/build-figcraft.sh" com **Reconectar**.
- **Preferências**: `PreferencePage` tem `aparencia, terminal, desenho, memoria, plugins, celular, android`. A página
  `desenho` (`PreferencesView.swift:144`) tem `designSection` (onde o Pastor desenha: Prévia, FigCraft, Perguntar) e
  `sandboxSection`. A página **Android** é o molde: o daemon baixa e instala (comandos `android.status`,
  `android.install`, `android.cancel`, só app, `exposedToMCP: false`), o app acompanha com `AndroidSetupModel` e o
  item da barra ganha selo `↓` / `!` (`PreferencePage.androidBadge`).
- **Download que já existe**: `AndroidDownload.fetch` (daemon): `URLSession` efêmera, só `https` em hosts listados
  (`github.com` restrito a `/adoptium/`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`),
  cada redirect conferido, arquivo movido só com 200 de URL permitida; `verify(_:sha256:)` em streaming;
  `AndroidInstaller` extrai numa `.collie-staging` e move no lugar só depois de conferido. O JDK baixado assim é
  executado pelo daemon como processo filho: é exatamente o caso do figcraft.
- **Raiz**: `Paths.defaultRoot` = `~/Library/Application Support/Collie`. Terminal sandboxado não escreve em lugar
  nenhum da home fora do projeto e caches (`SandboxProfile.swift:140`) e os dados do Collie nunca são liberáveis
  (`SandboxGrants.swift:44`): um agente sandboxado não consegue trocar o motor instalado.
- **Assinatura do daemon**: `collied` tem hardened runtime (`flags=0x10000(runtime)`), sem entitlements.
- **Licença**: MIT/Apache-2.0 (figcraft) + OFL-1.1 (fontes embutidas): redistribuir num arquivo separado é permitido
  desde que vão `licenses/` e o NOTICE.

## Metas

1. O dmg do Collie não leva o figcraft; o release do app não compila Rust.
2. Preferências › Desenho mostra o estado do motor (ausente, baixando, instalado vX, atualização disponível, erro) com
   **Baixar**, **Cancelar**, **Atualizar**, **Remover**, e progresso em bytes.
3. O motor baixado é verificado (sha256 fixado no app, assinatura Developer ID do mesmo time) antes de ser usado; um
   arquivo que não confere nunca é extraído nem executado.
4. O daemon resolve o motor em `<root>/figcraft` (Application Support) e depois no bundle, troca de motor sem reiniciar
   o daemon e sem perder arquivos de design.
5. Sem motor, o painel Design e `collie design *` dizem "baixe o motor de design em Preferências › Desenho", não
   "rode scripts/build-figcraft.sh".
6. Um workflow próprio compila, assina, notariza e publica o motor só quando o pin/patches mudam (ou à mão).
7. Quem tem v0.1.0 (motor embutido) continua funcionando; o build local de desenvolvimento continua funcionando sem rede.

## Não metas

- Atualização automática do motor ou do app (Sparkle etc.): a atualização disponível vem de um app novo que fixa um
  motor novo.
- Manifesto remoto assinado / canal de atualização do motor independente do app (ver Abordagens).
- Intel / macOS < 15.
- draw.io (`vendor/drawio`, 34 MB): mesmo padrão serve depois (seção Extensão), não entra aqui.
- Defender contra código sem sandbox rodando como o mesmo usuário (terminal livre, outro app): ele já pode trocar
  `~/.zshrc`; a cadeia aqui protege contra rede, CDN/GitHub comprometido e agentes sandboxados.

## Anti-metas

- O app baixar e executar algo que não confere com o hash fixado no próprio binário assinado do app.
- Download sem o usuário clicar (inclusive "baixa ao abrir o painel Design").
- Apagar ou mexer em `<root>/design/` (arquivos do usuário) ao instalar, atualizar ou remover o motor.
- A release do motor virar a "latest" do repo e quebrar `releases/latest/download/Collie.dmg`.
- Release do app que fixa um motor que não existe publicado.

## Abordagens consideradas

**A. Hash fixado no app + release própria por versão do motor (recomendada).** Um arquivo no repo
(`Resources/figcraft-engine.json`) diz versão, URL, tamanho e sha256 do asset; entra no binário (recurso do bundle,
selado pela assinatura). O app só aceita esse arquivo exato. Atualizar o motor = workflow publica → commit do novo
pin → próximo release do app. Simples, sem chave nova, verificação offline do lado do app, nenhum servidor no
caminho de confiança (GitHub só entrega bytes). Custo: um motor novo só chega com um app novo — ok, porque o
`DesignService` depende dos patches (ex.: 0005 fontes em runtime), então motor e app já andam juntos.

**B. Manifesto remoto assinado (ed25519/minisign) que o app consulta.** Permite motor novo sem release do app e
"atualização disponível" real. Custo: chave de assinatura nova para guardar e girar (mais um secret), um formato de
manifesto, rollback/freeze attacks a tratar (versão mínima, expiração), e o app passa a aceitar binários que o app
assinado nunca viu. Não compensa enquanto motor e app mudam juntos.

**C. Só confiar na assinatura Developer ID + notarização (sem hash).** Qualquer binário do time passaria, inclusive
um motor antigo com bug conhecido (downgrade). O hash fixa o arquivo exato; a assinatura fica como segunda camada.

**Quem baixa — daemon (recomendado) vs app.** O daemon já tem o molde (Android), é quem executa o motor, segue
rodando com a janela fechada, e escreve em `<root>` (é dele). O app baixar exigiria o app escrever em `<root>` e
avisar o daemon para trocar; ganha nada. Rodar sob launchd não atrapalha: Application Support não é pasta protegida
por TCC (Documents/Desktop/Downloads são; por isso o app vai para `/Applications`).

## Design

### 1. O pin (`Resources/figcraft-engine.json`)

```json
{ "version": "0.7.0-c1", "figcraft": "v0.7.0", "commit": "47438dd4a2e8b49a7e6bb3dfd480262dadc37f12",
  "inputs": "<sha256 de build-figcraft.sh + patches/figcraft/*.patch>",
  "url": "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v0.7.0-c1/figcraft-0.7.0-c1-arm64.tar.gz",
  "size": 51400000, "sha256": "<64 hex>" }
```

- `version` = tag do figcraft + `-c<N>` (revisão do Collie: patches/flags). `N` sobe à mão quando `inputs` muda.
- `inputs` é o mesmo hash que hoje é chave do cache (`build-figcraft.sh` + patches): o workflow do motor confere que
  bate; o release do app confere que o asset publicado bate com `sha256` (ver §6). Pin desatualizado falha no CI, não
  no usuário.
- `bundle-app.sh` copia o arquivo para `Contents/Resources/` (selado pela assinatura do app). O daemon o lê de
  `<Helpers>/../Resources/figcraft-engine.json` (env `COLLIE_FIGCRAFT_PIN` nos testes).

### 2. O asset

`figcraft-<version>-arm64.tar.gz` com `figcraft/{bin/figcraft-server,bin/figcraft-cli,web/…,licenses/…,NOTICE-figcraft,
engine.json}`; `engine.json` = `{version, commit, teamId}`. Os dois binários assinados Developer ID com hardened
runtime e `--timestamp`, notarizados (zip de `bin/` enviado ao `notarytool`; ticket não grampeia em Mach-O solto, o
Gatekeeper consulta online se precisar). Mora numa **release própria do repo público** `figcraft-v<version>`,
`--prerelease --latest=false`, imutável (o workflow recusa sobrescrever). Mais um `.sha256` ao lado, para humanos.

### 3. Instalação (daemon, `FigcraftInstaller`, actor, no molde do `AndroidInstaller`)

1. Usuário clica **Baixar** (o botão já mostra o tamanho: "Baixar motor de design (49 MB)"). App chama
   `design.engine.install`. Sem outra confirmação: o clique é a confirmação; não há download sem clique.
2. Espaço livre ≥ 3 × `size` em `<root>`; senão erro "Espaço insuficiente".
3. `fetch` = `AndroidDownload.fetch` generalizado: `https`, hosts permitidos; `github.com` só sob
   `/ysraelmoreno/collie/releases/download/figcraft-v` (além de `/adoptium/`). URL vem só do pin, nunca de argumento.
   Destino `<root>/.figcraft-staging/asset.tar.gz`. Progresso `(bytes, total)` no job.
4. **sha256 do arquivo inteiro antes de qualquer extração** (`AndroidDownload.verify`). Não bateu → apaga o staging,
   job `failed` com "O arquivo baixado não confere (sha256). Nada foi instalado." e **sem retry automático** (botão
   **Tentar de novo**). Nada é extraído.
5. `/usr/bin/tar -xzf` no staging (conteúdo já é o nosso, conferido pelo hash). Confere layout: os dois executáveis,
   `web/index.html`, `engine.json.version == pin.version`.
6. Assinatura: `SecStaticCodeCheckValidityWithErrors` (strict) em cada binário com o requisito
   `anchor apple generic and certificate leaf[subject.OU] = "<teamId do pin>"`. Redundante com o hash de propósito:
   pega um pin errado num commit.
7. `xattr -d com.apple.quarantine` recursivo, se houver (ver §4).
8. Troca: `figcraft` → `.figcraft-old`, staging/figcraft → `figcraft`, apaga `.figcraft-old`. Na subida do daemon:
   `figcraft` ausente e `.figcraft-old` presente → restaura; staging órfão → apaga (como o Android).
9. Recarrega o motor (§5). Job `done`.

`design.engine.cancel` cancela a Task (cancela o download), limpa o staging. `design.engine.remove`: recarrega sem
App Support (§5) e então apaga `<root>/figcraft`; nunca toca `<root>/design/`.

### 4. Gatekeeper, quarentena, hardened runtime (o que vale para binário baixado e executado pelo daemon)

- **Quarentena**: `com.apple.quarantine` é posta por quem baixa, quando é app com `LSFileQuarantineEnabled` ou chama a
  API de quarentena; `URLSession` num processo comum não põe. Portanto o `posix_spawn` do daemon **não** passa pelo
  Gatekeeper (syspolicyd só avalia na primeira execução de arquivo em quarentena). Por isso a segurança vem do hash +
  requisito de assinatura feitos pelo próprio Collie, não do Gatekeeper. Ainda assim o passo 7 remove a quarentena se
  algum caminho futuro a puser (evita prompt "baixado da internet" num processo sem UI e a checagem online de
  notarização offline). A confirmar no teste manual (Verificação): `xattr -l` nos arquivos instalados.
- **Kernel/AMFI**: em arm64 todo Mach-O precisa de assinatura válida; página adulterada = processo morto. Vale igual
  para o baixado.
- **Hardened runtime / library validation do `collied`**: só restringe dylibs carregadas *dentro* do `collied`. O
  figcraft é outro processo (exec), com a própria assinatura; a library validation dele (hardened runtime do
  `figcraft-server`) só vê bibliotecas do sistema (`otool -L`), então passa. Nada de entitlement novo no daemon.
- **Notarização**: exigida pela política do projeto (tudo que sai assinado Developer ID sai notarizado) e útil se um
  dia o arquivo for aberto à mão com quarentena; não é o que protege o fluxo normal.
- A cada subida do servidor (não a cada chamada), o daemon repete o passo 6 nos binários de App Support (barato,
  pega troca por processo do usuário sem o time certo). Falhou → trata como ausente com erro "Motor alterado,
  baixe de novo".

### 5. Resolução e troca no daemon

`FigcraftEngine` (CollieCore, função pura testável): candidatos em ordem —
1. `COLLIE_FIGCRAFT_DIR` (dev/testes, sem checagem de versão);
2. `<root>/figcraft` (Application Support), se layout válido e `engine.json` legível;
3. `<Helpers>/../Resources/figcraft` (bundle: v0.1.0 e build local);
4. DEBUG: `vendor/figcraft` do repo (já existe no painel).

Resultado: `{dir, version, source: env|appSupport|bundle|vendor}` ou ausente. Estado para a UI:
`absent` | `installed(v)` | `updateAvailable(installed, pinned)` (instalado ≠ pin; continua usável) | job
`downloading/verifying/installing/failed`.

`FigcraftServer` e `DesignService` deixam de guardar o caminho em `let`: recebem `engine: @Sendable () -> URL?`
(resolvido em `start()` / ao criar um cliente). `CommandRouter.reloadEngine()`: `design.stop()` (fecha os
`figcraft-cli mcp`), `figcraft.stop()`; a próxima chamada sobe o novo. Painéis Design abertos já reconectam sozinhos
quando o servidor cai (comportamento atual). Não troca durante `hold(true)` (backup): o install espera o hold soltar
(erro `busy` "backup em andamento" se passar de 60 s). Arquivos de design: ficam em `<root>/design/server`, que o
servidor novo abre igual; o `stop()` atual (TERM) é o mesmo usado no backup, então o servidor grava antes de sair.

Sem motor: `ensureRunning` lança `.unavailable` "Motor de design não instalado. Baixe em Preferências › Desenho
(collie design engine install)" — mensagem nova substitui `notBundled`.

### 6. Comandos (só app, `exposedToMCP: false`, como `android.*`)

- `design.engine.status` → `{state, installed?: {version, source}, pinned: {version, size}, job?: {phase, bytes,
  total, error?}}`
- `design.engine.install` → `{job}` na hora; acompanha por `status` (poll 0,5 s como o Android) ou evento.
- `design.engine.cancel`, `design.engine.remove` (recusa com `busy` se há job).

CLI: `collie design engine [status|install|remove]` para o dono (não aparece no MCP: agente não baixa binário).

### 7. UX

Preferências › **Desenho**, nova seção "Motor de design" acima de `designSection`; selo na barra como o Android
(`↓` baixando, `!` erro ou atualização). Palavras-chave da página ganham "motor baixar instalar remover atualizar".

```
Motor de design (FigCraft)
  ausente:      Necessário para o painel Design e `collie design`.   [Baixar (49 MB)]
  baixando:     ███████░░░  31 de 49 MB                               [Cancelar]
  verificando:  Conferindo assinatura…
  instalado:    v0.7.0-c1 · 109 MB em disco · Application Support      [Remover]
                (bundle: "v0.7.0 · embutido no app" e sem Remover)
  atualização:  Instalado v0.7.0-c1 · disponível v0.8.0-c1 (52 MB)     [Atualizar] [Remover]
                Os painéis Design abertos vão reconectar.
  erro:         Falhou: <mensagem>                                     [Tentar de novo]
  sem rede:     Sem conexão. Tente de novo quando estiver online.      [Tentar de novo]
```

**Remover** pede confirmação ("Os arquivos de design continuam; o painel Design fica indisponível até baixar de
novo."). Painel Design sem motor: em vez de "Motor de design indisponível / Rode scripts/build-figcraft.sh", mostra
"Motor de design não instalado" + botão **Abrir Preferências** (vai direto à página Desenho) no lugar de
**Reconectar**. `DesignPanel.webDirectory` vira função chamada a cada `connect()` usando o mesmo `FigcraftEngine`
(mesma regra, mesmo disco: app e daemon escolhem o mesmo dir; a troca é rename, então não há meio-termo).

### 8. Migração

- v0.1.0 instalada: não muda nada (só conhece o bundle).
- v0.1.0 → v0.2 (dmg sem motor): o motor sai junto com o app velho; o daemon novo acha `absent`; Preferências e o
  painel oferecem **Baixar**. Um clique, 49 MB. Arquivos em `<root>/design/` intactos. A nota da release diz isso.
- Volta de v0.2 para v0.1.0: v0.1.0 usa o próprio bundle; `<root>/figcraft` fica parado, inofensivo.
- Build local com `vendor/figcraft`: continua embutindo (§9), `source: bundle`.

### 9. CI e build local

- **Novo `.github/workflows/figcraft.yml`**: gatilho `push` em `main` com `paths: [scripts/build-figcraft.sh,
  patches/figcraft/**, Resources/figcraft-engine.json]` + `workflow_dispatch`. Passos: lê `version` do pin; se a
  release `figcraft-v<version>` já existe → sai verde (nada a fazer); confere `inputs` do pin com o hash atual (falha
  "suba -c<N> e o inputs no pin"); cache do `target/` do cargo e das ferramentas (`vendor/figcraft-tools`) por
  `inputs`; `scripts/build-figcraft.sh`; assina os dois binários (mesmo keychain temporário do `release.yml`, extrair
  para um script/composite compartilhado), notariza, empacota (`scripts/package-figcraft.sh`), cria a release
  `--prerelease --latest=false` e imprime o `sha256`/`size` para o commit do pin. Timeout 300 min.
- **Atualizar o pin**: commit à mão com `sha256`/`size` impressos (ou o workflow abre um PR — ver Minhas chamadas).
- **`release.yml`**: some o cache e o build do figcraft; novo passo barato "Conferir motor": baixa o asset do pin e
  confere `sha256` (falha o release se o motor fixado não está publicado). Timeout cai para ~120 min.
- **`release.sh`**: exporta `COLLIE_BUNDLE_FIGCRAFT=0`; depois do bundle, falha se `Contents/Resources/figcraft`
  existir.
- **`bundle-app.sh`**: copia `figcraft-engine.json` sempre; copia o motor só se `vendor/figcraft` existe e
  `COLLIE_BUNDLE_FIGCRAFT` ≠ `0` (padrão: copia, para o dono seguir usando o build local sem rede). O aviso
  "vendor/figcraft missing" vira nota ("motor fica para download").
- `NOTICE-figcraft` no app passa a dizer "baixado sob pedido para `<root>/figcraft/`, licenças em
  `figcraft/licenses/`"; o mesmo texto vai dentro do asset.

### 10. Tamanho, offline, custo

- dmg: 98,6 MB − ~51 MB (figcraft comprimido) ≈ **47–50 MB**; app instalado 206 → ~97 MB. Download do motor ~49 MB,
  109 MB em disco.
- Offline / primeiro uso: Collie abre e funciona sem o motor; só design fica indisponível com a mensagem de baixar.
  Download falho não deixa nada pela metade (staging).
- CI: release do app sem Rust (−20 a 40 min a frio, e o cache de ~100 MB some do `release.yml`). O workflow do motor
  roda só quando o pin muda (poucas vezes por mês no máximo).
- Riscos: (a) pin com hash errado → todo usuário vê "não confere": mitigado pelo passo "Conferir motor" do
  `release.yml`; (b) release do motor apagada no GitHub → download 404, mensagem de erro; mitigado por releases
  imutáveis e nunca apagar tags `figcraft-v*`; (c) rename de `figcraft-cli` mid-uso: processos já abertos seguem com
  o inode antigo e são fechados pelo `reloadEngine`; (d) GitHub fora do ar → só o primeiro download falha.

## Decisões do dono (vindas do pedido)

- dmg sem figcraft; botão em Preferências com progresso, remover e atualizar.
- Ordem de busca: Application Support → bundle.
- Sem motor, painel mostra "baixe o motor" em vez de erro.
- Workflow separado, só quando o pin muda; asset assinado Developer ID e notarizado; o app guarda o sha256 fixado.

## Minhas chamadas (conferir)

1. **Hash fixado no app (A), sem manifesto remoto.** "Atualização disponível" só aparece depois de atualizar o app.
2. **Daemon baixa**, não o app (molde Android; o agente não tem comando MCP para isso).
3. **Diretório `<root>/figcraft`** (= `~/Library/Application Support/Collie/figcraft`), um só, sem versões lado a lado.
4. **Versão `0.7.0-c<N>`** e tag `figcraft-v0.7.0-c1` (o pedido sugeria `figcraft-v0.7.0`; o `-cN` permite republicar
   após mudar só patches sem sobrescrever release).
5. **Motor desatualizado continua usável** com aviso de atualização (não bloqueia o painel).
6. **Sem confirmação extra** além do clique em "Baixar (49 MB)"; Remover pede confirmação.
7. **Build local continua embutindo** o motor quando `vendor/figcraft` existe; só o release força sem.
8. **Pin atualizado por commit manual** depois do workflow (não por PR automático): menos permissões no workflow.
9. **Requisito de assinatura conferido no install e a cada subida do servidor**, com o team ID gravado no pin.
10. Tamanho no botão é do download (49 MB), não do disco.

## Fica para quem construir

- Nomes exatos dos tipos (`FigcraftEngine`, `FigcraftInstaller`) e se o progresso vai por poll ou evento.
- Extrair `AndroidDownload.fetch`/`verify` para um `Download` comum ou só ampliar a allowlist.
- Script/composite compartilhado de keychain entre `release.yml` e `figcraft.yml`.

## Extensão (fora deste escopo)

draw.io (`vendor/drawio`, 34 MB, só web, sem binário): mesmo pin + release `drawio-v…` + instalador; sem passo de
assinatura (não há Mach-O), só hash.

## Verificação

Testes só com `--filter`, nunca a suíte inteira:

- `swift test --filter FigcraftEngineTests`: ordem env → App Support → bundle; layout inválido ignorado;
  `updateAvailable` quando versão ≠ pin; `.figcraft-old` restaurado.
- `swift test --filter FigcraftInstallerTests` (fetch falso injetado como no Android, sem rede): sucesso; sha256
  errado → nada extraído, `<root>/figcraft` intacto, staging limpo; host/URL fora da allowlist recusado; cancelar no
  meio; espaço insuficiente; assinatura com time errado (binário ad-hoc de teste) → falha; remover não toca
  `<root>/design/`.
- `swift test --filter FigcraftServerTests` / `DesignServiceTests` existentes + caso novo: `reloadEngine` com o
  servidor falso de teste troca o binário sem reiniciar o daemon.
- `swift test --filter DesignPanelTests` / `PreferencePageTests`: mensagem e botão sem motor; selo da barra.
- Sem rede: o asset de teste é um `tar.gz` gerado no próprio teste (binário assinado ad-hoc; o checador de
  assinatura é injetado, como o `fetch`), entregue pelo fetch falso. Um servidor HTTP local não serve: a allowlist só
  aceita https nos hosts do GitHub, de propósito. Manual com rede, uma vez, após o primeiro `figcraft.yml`: app de
  release instalado, baixar o motor, `xattr -l` e `codesign -dv` nos binários instalados (confirma §4), abrir um
  painel Design, Remover, Baixar de novo.
- `release.yml`: conferir num `workflow_dispatch` de tag de teste que `Contents/Resources/figcraft` não está no dmg e
  que o dmg ficou ~50 MB.

## Tarefas (independentes, em ordem sugerida)

1. Pin `Resources/figcraft-engine.json` + `FigcraftEngine` (resolução, estado) + testes.
2. `FigcraftServer`/`DesignService` com motor resolvido por closure + `reloadEngine` + mensagem nova sem motor.
3. `FigcraftInstaller` (download, hash, extração, assinatura, quarentena, troca, cancelar, remover) + allowlist.
4. Comandos `design.engine.*` no protocolo/roteador + `collie design engine` no CLI.
5. Preferências › Desenho: seção "Motor de design", modelo no molde de `AndroidSetupModel`, selo na barra.
6. `DesignPanel`: `webDirectory` dinâmico, estado "não instalado" com **Abrir Preferências**.
7. `scripts/package-figcraft.sh` + `.github/workflows/figcraft.yml` (+ keychain compartilhado); primeira publicação
   `figcraft-v0.7.0-c1` e commit do pin.
8. `release.yml` sem figcraft + passo "Conferir motor"; `release.sh` com `COLLIE_BUNDLE_FIGCRAFT=0` e checagem;
   `bundle-app.sh` com a variável; `NOTICE-figcraft`, `docs/release.md`, nota de release sobre a migração.
