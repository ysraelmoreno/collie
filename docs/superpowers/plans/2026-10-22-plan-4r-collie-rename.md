# Plano 4R — Orq vira Collie

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** renomear o projeto inteiro de Orq para Collie (app, CLI, daemon, módulos, ids, variáveis) e trocar a marca pela logo "Herd", sem perder nenhum dado de quem já usa o Orq.

**Architecture:** um codemod mecânico troca todos os nomes de uma vez (Task 1). Depois, código de upgrade explícito devolve a compatibilidade com o que o Orq deixou em disco: pasta de dados, LaunchAgent, preferências, extensões de arquivo, URLs salvas e as pastas `.orq/` dentro dos repositórios do usuário (Tasks 2–3). Por fim, a marca (Task 4) e os docs (Task 5).

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, launchd, `iconutil`.

**Spec:** este plano é a spec. A decisão do usuário (2026-10-22) foi o rename completo com migração automática dos dados, e a logo escolhida foi a ideia 2, "Herd", do canvas https://claude.ai/artifact/FQ5E12kYdzn8svAkDeoYsL. A spec de produto continua sendo `docs/superpowers/specs/2026-10-18-modular-orchestrator-design.md`.

## Global Constraints

| Antes | Depois |
|---|---|
| App `Orq` / `Orq.app` / bundle `dev.orq.app` | `Collie` / `Collie.app` / `dev.collie.app` |
| Daemon `orqd`, LaunchAgent `dev.orq.daemon` | `collied`, `dev.collie.daemon` |
| CLI/MCP `orq`, MCP server `"orq"` | `collie`, `"collie"` |
| Módulos `Orq*` (`OrqCore`, `OrqDaemonKit`, …) e pastas `Sources/Orq*`, `Tests/Orq*Tests` | `Collie*` |
| Dados `~/Library/Application Support/Orq`, logs `~/Library/Logs/Orq`, socket `run/orqd.sock` | `…/Collie`, `~/Library/Logs/Collie`, `run/collied.sock` |
| Variáveis `ORQ_*` | `COLLIE_*` (sem aceitar as antigas) |
| Esquemas `orq-artifact://`, `orq-design://` | `collie-artifact://`, `collie-design://` |
| Arquivos `.orqpartitura`, `.orqbackup` | `.colliepartitura`, `.colliebackup` (os antigos ainda abrem) |
| Pasta no repo `.orq/` (floors, memory, cache), branch de floor `orq/<nome>` | `.collie/`, `collie/<nome>` (repos antigos: ver Task 2) |
| Tema `Color.orqText`, `.orqUI(…)`, `OrqColor`, `OrqButtonStyle`… | `Color.collieText`, `.collieUI(…)`, `CollieColor`, `CollieButtonStyle`… |
| `TERM_PROGRAM=Orq`, `<meta name="generator" content="Orq">` | `Collie` |

- **Nunca apagar dado do usuário.** O que sai do caminho vai para um nome novo ou fica no lugar.
- Os docs históricos em `docs/superpowers/{plans,specs,spikes}` (exceto este plano) **não** são reescritos, porque registram o projeto quando ele se chamava Orq.
- Reiniciar o daemon mata os terminais abertos. O upgrade acontece quando o usuário abre o `Collie.app` novo, e é ele quem decide quando.
- Continuam valendo todas as restrições de projeto: cordas, token admin, clean-room, nada sai da máquina e o push é do usuário.
- Suíte completa: `perl -e 'alarm 900; exec @ARGV' swift test`. Nunca rodar duas suítes ao mesmo tempo.

## Review Focus

1. **Daemon antigo vivo durante a migração.** Se o `orqd` ainda estiver escrevendo em `…/Orq`, mover a pasta corrompe os dados. O app derruba `dev.orq.daemon` **antes** de instalar `dev.collie.daemon`. O `collied` não migra enquanto `Orq/run/orqd.sock` aceitar conexão: só registra isso no log e usa `…/Collie` vazio, sem mexer na pasta antiga.
2. **As duas pastas já existem** (por exemplo, depois de uma tentativa interrompida). Não há merge: usa `…/Collie`, deixa `…/Orq` intacto e registra no log.
3. **Caminhos absolutos para `…/Orq` guardados nos dados** (por exemplo, `--data` do figcraft-server e caminhos de workspace). Depois de mover a pasta, `…/Orq` vira um symlink para `…/Collie`, e esses caminhos continuam resolvendo.
4. **Repositório do usuário com `.orq/memory` commitada.** A memória continua em `.orq/` nesse repositório; nada é movido nem commitado sozinho.
5. **Canvas salvo com um painel de navegador em `orq-artifact://…`.** Ao reabrir, a URL vira `collie-artifact://…` e a página abre.

---

### Task 1: Codemod de nomes

**Files:** tudo em `Package.swift`, `Package.resolved` (só se mencionar), `Sources/**`, `Tests/**` (menos `Tests/Fixtures/**` binários), `scripts/**`, `Resources/Info.plist`, `README.md`. As pastas `Sources/Orq*` → `Sources/Collie*`, `Sources/orq` → `Sources/collie`, `Sources/orqd` → `Sources/collied`, `Tests/Orq*Tests` → `Tests/Collie*Tests` e os arquivos com `Orq` no nome (`OrqApp.swift`, `OrqOrientation.swift`…) via `git mv`.

**Interfaces:**
- Produces: todos os nomes da tabela de Global Constraints. Os produtos SwiftPM passam a ser `CollieApp`, `collied` e `collie`.

- [ ] **Step 1:** Renomear as pastas e os arquivos com `git mv`.
- [ ] **Step 2:** Trocar o texto com três regras, sensíveis a maiúsculas e aplicadas nesta ordem: `ORQ` → `COLLIE`; `Orq` → `Collie`; `orq` → `collie` **só** quando não vier depois de uma letra (regex `(?<![A-Za-z])orq`, que protege "porque" e afins). O script é descartável e não é commitado. Não tocar `docs/superpowers/**`, `patches/**` (Task 4) nem `vendor/**`.
- [ ] **Step 3:** `scripts/bundle-app.sh` gera `build/Collie.app` com `Contents/Helpers/{collie,collied}` (o mesmo motivo de APFS do comentário atual). `Info.plist`: `CFBundleIdentifier` `dev.collie.app`, `CFBundleName`/`CFBundleExecutable` `Collie`.
- [ ] **Step 4:** Verificar.
  - `swift build` passa.
  - `git grep -nP '(?<![A-Za-z])orq|Orq|ORQ' -- Sources Tests scripts Resources Package.swift` não retorna nada.
  - A suíte completa fica verde. Testes que afirmam nomes, por exemplo `"orq"` como serverInfo do MCP, mudam junto com o código.
- [ ] **Step 5:** Commit `refactor: rename Orq to Collie`.

### Task 2: Upgrade do daemon (dados, repos, formatos)

**Files:**
- Create: `Sources/CollieDaemonKit/LegacyOrq.swift`, `Tests/CollieDaemonKitTests/LegacyOrqTests.swift`
- Modify: `Sources/collied/main.swift`, `FloorManager.swift`, `Memory/MemoryService.swift`, `Partituras/PartituraApplier.swift`, `Partituras/PartituraStore.swift`, `CommandRouter.swift` (detecção de ground), `DataBackup.swift`

**Interfaces:**
- Produces:
  - `enum LegacyOrq`, com os valores fixos `dataRootName = "Orq"`, `socketName = "orqd.sock"`, `repoDir = ".orq"`, `branchPrefix = "orq/"`, `partituraExt = "orqpartitura"`, `backupExt = "orqbackup"`.
  - `static func migrateDataRoot(old: URL, new: URL, oldDaemonAlive: () -> Bool) -> MigrationOutcome`, com `enum MigrationOutcome: Equatable { case moved, nothingToMove, bothExist, oldDaemonAlive, failed(String) }`.
  - `static func repoDirName(repoRoot: URL) -> String`, que retorna `".orq"` se `<repo>/.orq` existe e `<repo>/.collie` não; caso contrário, `".collie"`.

- [ ] **Step 1: Testes que falham** (`LegacyOrqTests`, todos em diretórios temporários):
  - `movesRootAndLeavesSymlink`: `old` com `a.txt` e `new` ausente → `.moved`; `new/a.txt` existe; `old` é um symlink que resolve para `new`.
  - `secondRunIsNoop`: rodar outra vez → `.nothingToMove`, e o symlink continua lá.
  - `bothExistTouchesNothing`: as duas pastas existem → `.bothExist`; o conteúdo das duas não muda.
  - `oldDaemonAliveTouchesNothing`: `oldDaemonAlive` retorna `true` → `.oldDaemonAlive`; `old` intacto.
  - `renamesPartituraFiles`: `old/partituras/x.orqpartitura` → depois da migração, existe `new/partituras/x.colliepartitura`, e `.removed/` também é renomeado.
  - `repoDirKeepsLegacy`: `.orq` existe e `.collie` não → `".orq"`; repo vazio → `".collie"`; as duas existem → `".collie"`.
  - `groundDetectsBothDirs`: um cwd em `/r/.orq/floors/f` e outro em `/r/.collie/floors/f` resolvem os dois para `/r`.
  - `applierRefusesLegacyBranch`: `refs/heads/orq/x` existe → aplicar uma partitura que cria o floor `x` é recusado com a mesma mensagem de branch existente.
  - `backupManifestReadsLegacyKey`: um manifesto com `orqVersion` é aceito; o novo escreve `collieVersion`.
- [ ] **Step 2:** Rodar `swift test --filter LegacyOrqTests` e ver todos falharem.
- [ ] **Step 3: Implementar.**
  - **`migrateDataRoot`:** usa `rename(2)` e depois `symlink(2)` de `old` para `new`. Na mesma rodada, renomeia os arquivos `*.orqpartitura` em `partituras/` e em `partituras/.removed/`.
  - **No `collied/main.swift`:** chama `migrateDataRoot` antes de qualquer uso de `Paths` e antes do import pendente. `oldDaemonAlive` faz `connect` em `<old>/run/orqd.sock` e retorna `true` só se a conexão for aceita. O resultado vai para o log (`collied: legacy Orq data: <outcome>`).
  - **`repoDirName`:** substitui o `".orq"` literal em FloorManager (floors, memory, commit `collie: memory`), MemoryService (memory, cache, exclude) e PartituraApplier.
  - **Branches:** um floor novo usa `collie/<nome>`. O applier checa os dois prefixos.
  - **Manifesto do backup:** decodifica `collieVersion` e, se faltar, `orqVersion`.
  - **Import de backup:** `admin.data.import` aceita `.orqbackup` e `.colliebackup`; o formato interno é o mesmo.
- [ ] **Step 4:** Rodar o filtro (verde) e a suíte completa (verde).
- [ ] **Step 5:** Commit `feat(upgrade): carry Orq data, repos and formats over to Collie`.

### Task 3: Upgrade do app (LaunchAgent, preferências, URLs, arquivos)

**Files:**
- Modify: `Sources/CollieClient/DaemonLauncher.swift`, `Sources/CollieApp/CollieApp.swift`, `Sources/ColliePlugins/BrowserPanel.swift`, `Sources/CollieApp/PartiturasSheet.swift`, o painel de abrir backup em `CollieApp.swift`
- Test: `Tests/CollieClientTests/DaemonLauncherTests.swift`, `Tests/CollieAppTests/LegacyDefaultsTests.swift`, `Tests/ColliePluginsTests/BrowserPanelTests.swift` (ou o arquivo de testes do navegador que já existe)

**Interfaces:**
- Consumes: os nomes legados de `LegacyOrq` (Task 2). Se `LegacyOrq` ficar fora do alcance do `CollieClient`, as strings `"dev.orq.daemon"` e `"dev.orq.app"` ficam como constantes `legacy…` no próprio arquivo.
- Produces:
  - `DaemonLauncher.retireLegacy(agentsDir: URL, launchctl: Launchctl) -> Bool`: devolve `true` se havia um agente antigo.
  - `static func migrateDefaults(from legacyDomain: String, into d: UserDefaults) -> Int`: devolve quantas chaves copiou.
  - `BrowserPanel.normalize(_ url: String) -> String`.

- [ ] **Step 1: Testes que falham**:
  - `retiresLegacyAgentBeforeInstall`: com `dev.orq.daemon.plist` no `agentsDir` falso, a ordem das chamadas ao launchctl falso é `bootout gui/<uid>/dev.orq.daemon`, depois a remoção do plist antigo, e só então o `bootstrap` de `dev.collie.daemon`. Sem o plist antigo, não há nenhuma chamada legada.
  - `copiesLegacyDefaultsOnce`: com o domínio fonte `{"consent": true, "new.claudeFolders": ["/r"]}`, a primeira chamada devolve 2 e as chaves aparecem; a segunda devolve 0 (marcador `collie.migratedFromOrq`). Uma chave que já existe no destino não é sobrescrita.
  - `normalizesLegacyArtifactURL`: `orq-artifact://app/x/index.html` vira `collie-artifact://app/x/index.html`, `https://a.dev` não muda, e `orq-design://…` também vira `collie-design://…`.
- [ ] **Step 2:** Ver os testes falharem.
- [ ] **Step 3: Implementar.**
  - **`retireLegacy`:** é chamado no começo da instalação, antes do `bootout` e do `bootstrap` do agente novo, e reaproveita a espera que já existe (exit 5). Remover o plist antigo é permitido porque ele é config gerada pelo próprio app, não dado do usuário.
  - **`migrateDefaults`:** lê `UserDefaults.standard.persistentDomain(forName: "dev.orq.app")` e roda uma vez no `init` do app.
  - **`normalize`:** é aplicado onde o painel de navegador carrega a URL do estado salvo.
  - **Painéis de abrir arquivo:** aceitam as duas extensões, tanto nas partituras quanto no backup.
- [ ] **Step 4:** Rodar os filtros dos testes e depois a suíte completa (verde).
- [ ] **Step 5:** Commit `feat(upgrade): retire the Orq launch agent, carry preferences and saved URLs`.

### Task 4: Marca Collie (logo Herd, ícone, figcraft)

**Files:**
- Create: `Resources/AppIcon.svg`, `Resources/AppIcon.icns`, `scripts/make-icon.sh`, `Sources/CollieTheme/CollieMark.swift`, `Tests/CollieThemeTests/CollieMarkTests.swift`
- Modify: `Resources/Info.plist` (`CFBundleIconFile` = `AppIcon`), `scripts/bundle-app.sh` (copia o `.icns` para `Contents/Resources`), `Sources/CollieApp/Shell.swift` (as duas ocorrências de `Text("collie")` da Task 1 ganham a marca ao lado), `patches/figcraft/*`, `scripts/build-figcraft.sh`

**Interfaces:**
- Produces: `public struct CollieMark: View` com `init(size: CGFloat)`, que desenha a geometria Herd num viewBox 200×200:
  - Arco: centro (100,100), raio 64, de −45° até +45° passando pela esquerda, traço 18 com ponta redonda, na cor do texto.
  - Três pontos de raio 11 em (92,82), (120,100) e (92,118), na cor do texto.
  - Um ponto de raio 16 em (145.3,54.7), na cor de destaque.
  - Paleta: tinta `#15171C`, papel `#F4F2ED`, destaque `#2F6BFF` no tema claro e `#6E9BFF` no escuro.
  - `static func arcPath(in rect: CGRect) -> Path` é exposto para teste.

- [ ] **Step 1: Teste que falha** `herdGeometry`. `CollieMark.arcPath(in: 200×200)`, traçado com largura 18, contém (36,100), o ponto mais à esquerda do arco, e não contém (100,100), o centro.
- [ ] **Step 2:** Implementar `CollieMark` e trocar o wordmark do Shell para marca + "collie".
- [ ] **Step 3: Ícone.**
  - `Resources/AppIcon.svg`: quadrado 1024 com cantos de 22% em tinta, com a marca Herd em papel e destaque ocupando cerca de 62% da largura.
  - `scripts/make-icon.sh`: renderiza o SVG com um trecho `swift` (via `NSImage(contentsOf:)`) para um `AppIcon.iconset` nos tamanhos 16, 32, 128, 256 e 512 (@1x e @2x), depois roda `iconutil -c icns`. Commitar o `.icns` gerado.
- [ ] **Step 4: Figcraft.**
  - Nos patches: `#orq=1` vira `#collie=1`, junto com o `DesignPanel`. As marcas de texto "Orq" viram "Collie". O arquivo `0001-orq-branding.patch` vira `0001-collie-branding.patch`, e o stamp vira `.collie-patches`.
  - Rodar `scripts/build-figcraft.sh` (~10 min) e `scripts/check-figcraft.sh`.
- [ ] **Step 5:** A suíte completa fica verde, incluindo os testes com o motor real do Design. `scripts/bundle-app.sh` gera `build/Collie.app` com o ícone.
- [ ] **Step 6:** Commit `feat(brand): Collie mark, app icon and figcraft patches`.

### Task 5: Docs e checklist humana

**Files:**
- Modify: `README.md`, `docs/superpowers/plans/2026-10-24-phase3-roadmap.md` (linha 4R)
- Create (scratchpad, git-ignored): `.superpowers/checklists/plan4r-collie.md`

- [ ] **Step 1: README.** Título "Collie" e uma frase "antes chamado Orq". Comandos, variáveis e caminhos com os nomes novos. Uma seção "Vindo do Orq" com:
  - o que migra sozinho: dados (com o symlink), LaunchAgent, preferências, partituras e URLs salvas;
  - o que fica: `.orq/` nos repositórios antigos e branches `orq/<nome>`;
  - o que o usuário faz: fechar o Orq, abrir o Collie e apagar `/Applications/Orq.app` quando quiser;
  - um aviso de que os terminais abertos fecham no upgrade.
- [ ] **Step 2: Checklist humana com os dados reais desta máquina.**
  - Fechar o Orq.app e rodar o bundle.
  - Abrir o Collie.app.
  - Conferir que canvas, memória, partituras, arquivos de design e backups estão presentes.
  - Conferir que `launchctl print gui/$UID/dev.orq.daemon` falha e que `dev.collie.daemon` roda.
  - Conferir que `~/Library/Application Support/Orq` é um symlink.
  - Num repositório com floor antigo, conferir que `land` funciona e que a memória ainda está em `.orq/memory`.
- [ ] **Step 3:** Commit `docs: Collie rename`.
