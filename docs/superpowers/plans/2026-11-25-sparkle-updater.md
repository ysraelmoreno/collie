# Sparkle como instalador do Collie — plano de implementação

> **Para agentes:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recomendado) ou superpowers:executing-plans.
> Os passos usam checkbox (`- [ ]`). Neste repositório as tarefas rodam pelo laço do Collie (`collie work`), com testes só por
> `--filter` (nunca a suíte inteira).

**Goal:** o Collie se atualiza pelo Sparkle 2 (checar, baixar, conferir, instalar com pedido de senha, relançar), sem derrubar
agentes ocupados sem aviso.

**Architecture:** `Sparkle` só no alvo `CollieApp`, embutido e assinado de dentro para fora em `bundle-app.sh`. O CI assina o DMG
notarizado com EdDSA e publica `appcast.xml` por último. Um wrapper no app liga o `SPUStandardUpdaterController` à página
Preferências › Atualizações e adia o relançamento enquanto houver agente ocupado. O `update.json` continua para os 0.2.x.

**Tech Stack:** Swift 6.2 / SwiftPM, Sparkle 2.x (binário xcframework), bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-25-sparkle-updater-design.md` (e, no que não muda,
`docs/superpowers/specs/2026-11-17-update-downloader-design.md`).

## Global Constraints

- Chave pública EdDSA (do dono, já gerada): `SUPublicEDKey` = `MTeyV4mjkdM4P3K2FJXryAAenZ4Dip/J2ONqJGVymgc=`. A privada vive no
  Keychain do dono e no secret `SPARKLE_ED_PRIVATE_KEY`; **nenhum arquivo, log ou teste a contém**. Testes usam chave descartável.
- `SUFeedURL` = `https://github.com/ysraelmoreno/collie/releases/latest/download/appcast.xml`.
- `SUAllowsAutomaticUpdates` falso; `SUEnableAutomaticChecks` verdadeiro; `SUEnableSystemProfiling` falso.
- `CFBundleVersion` = `MAJOR*1000000 + MINOR*1000 + PATCH` da tag `vX.Y.Z` (0.2.2 → `2002`); tag fora de `vX.Y.Z` é recusada.
- Sparkle só em `CollieApp`: `collied`, `collie` e os demais alvos não o linkam nem o importam.
- Binários do framework assinados com hardened runtime e `--timestamp` (a conferência de `release.sh` olha cada Mach-O).
- Versão do Sparkle fixada (`exact`), com mais de 2 semanas de publicada; ferramentas de CI (`sign_update`) fixadas por versão e sha256.
- Build local ("Collie Local", sem time) nunca inicia o Sparkle: reaproveitar `UpdateInstaller.refusal() == .localBuild`.
- `appcast.xml` sobe **depois** do DMG e do `update.json`. Nada de push/tag fora do release do dono.
- Segredos de assinatura são do dono: não criar, ler nem alterar secrets.

## Review Focus

- Tag fora do formato (`v1.2`, `v1.2.3-rc1`, `1.2.3`) no cálculo do build: recusa com mensagem, nunca número errado.
- `CFBundleVersion` não cresce com a tag (patch 999 → minor seguinte): a conta mantém a ordem (`0.2.999` < `0.3.0`).
- Appcast gerado sem a chave privada (secret ausente, fork): o passo falha o release, nunca publica appcast sem assinatura.
- Atualização oferecida com agente ocupado: o relançamento fica adiado até o dono escolher; "Depois" não perde a atualização.
- Build local com `SUPublicEDKey` no plist: o Sparkle não inicia e a página diz por quê.

---

### Task 1: `CFBundleVersion` derivado da tag e chaves do Sparkle no Info.plist

**Files:**
- Create: `scripts/ci/build-number.sh`, `scripts/ci/test-build-number.sh`
- Modify: `scripts/bundle-app.sh` (junto do `PlistBuddy` de `CFBundleShortVersionString`, linha ~24), `Resources/Info.plist`

**Interfaces:**
- Produces: `scripts/ci/build-number.sh <vX.Y.Z|X.Y.Z>` imprime o número (ex.: `2002`); sai 1 com `build-number: "<arg>" is not vX.Y.Z` em stderr.

- [ ] **Step 1: Escrever `test-build-number.sh`** (padrão de `test-update-manifest.sh`): casos `v0.2.2`→`2002`, `0.2.2`→`2002`, `v1.0.0`→`1000000`, `v0.2.999`→`2999` e `v0.3.0`→`3000` (ordem), recusa de `v1.2`, `v1.2.3-rc1`, `` e `vA.B.C`.
- [ ] **Step 2: Rodar `bash scripts/ci/test-build-number.sh`** e ver falhar (script ausente).
- [ ] **Step 3: Implementar `build-number.sh`** (regex `^v?([0-9]+)\.([0-9]+)\.([0-9]+)$`, aritmética bash; recusa MINOR ou PATCH ≥ 1000).
- [ ] **Step 4: `bundle-app.sh`:** quando `COLLIE_VERSION` existe, também `Set :CFBundleVersion "$(scripts/ci/build-number.sh "$COLLIE_VERSION")"`.
- [ ] **Step 5: `Resources/Info.plist`:** acrescentar `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAllowsAutomaticUpdates`,
  `SUEnableSystemProfiling` com os valores das Global Constraints; `CFBundleVersion` do git passa de `"1"` para `"1000"` (o build local
  nunca se atualiza; o valor só precisa ser maior que o de qualquer app antigo, `"1"`).
- [ ] **Step 6: Verificar:** o teste passa; `plutil -lint Resources/Info.plist` diz OK.
- [ ] **Step 7: Commit** `build(update): CFBundleVersion from the tag, Sparkle keys in Info.plist`.

### Task 2: Dependência, framework embutido e assinado, regra de arquitetura

**Files:**
- Modify: `Package.swift` (dependência e alvo `CollieApp`), `scripts/bundle-app.sh`, `scripts/ci/architecture-rules.txt`
- Test: `scripts/ci/test-check-architecture.sh` (um caso novo)

**Interfaces:**
- Consumes: o `Info.plist` da Task 1.
- Produces: `build/Collie.app/Contents/Frameworks/Sparkle.framework`, assinado; `CollieApp` linka `Sparkle`.

- [ ] **Step 1: Regra primeiro.** Em `architecture-rules.txt`: `forbid-closure collied Sparkle`, `forbid-closure collie Sparkle` e `forbid-import CollieCore Sparkle`; um caso em `test-check-architecture.sh` que falha se `collied` passar a depender dele. Rodar e ver passar/falhar conforme o padrão do arquivo.
- [ ] **Step 2: `Package.swift`:** `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "<2.x fixada>")` e `.product(name: "Sparkle", package: "Sparkle")` só em `CollieApp`, mais `linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]` (o app dentro de `Contents/MacOS`).
- [ ] **Step 3: `bundle-app.sh`:** depois de copiar `Collie`, copiar `$BIN/Sparkle.framework` (ou o do `.build/artifacts`, conforme onde o SwiftPM o deixa; conferir com `find .build -name Sparkle.framework`) para `Contents/Frameworks/` e assinar **de dentro para fora** com `$SIGN --options runtime ${TS[@]}`: `Autoupdate`, `Updater.app`, os XPC (se existirem), o framework, e só então o app (trocar `--deep` do app por assinatura explícita dos nested já feita; manter o `codesign -v`).
- [ ] **Step 4: Verificar:** `swift build -c release --product CollieApp` compila; `scripts/bundle-app.sh` termina com `ok:`; `codesign --verify --deep --strict build/Collie.app` passa; `otool -L build/Collie.app/Contents/MacOS/Collie | grep Sparkle` mostra `@rpath/Sparkle.framework`; `scripts/ci/check-architecture.sh` passa.
- [ ] **Step 5: Commit** `build(update): Sparkle framework embedded and signed inside out`.

### Task 3: Appcast assinado no release

**Files:**
- Create: `scripts/ci/appcast.sh`, `scripts/ci/test-appcast.sh`
- Modify: `.github/workflows/release.yml` (passo novo entre "Manifesto" e "GitHub Release"; `ASSETS` ganha `build/appcast.xml` por último; passo de conferência), `docs/release.md`

**Interfaces:**
- Produces: `scripts/ci/appcast.sh <tag vX.Y.Z> <dmg> <Collie.app> <out.xml>`; lê a chave privada de `SPARKLE_ED_PRIVATE_KEY` (stdin da ferramenta, nunca argv nem arquivo); `sign_update` vem de `SPARKLE_SIGN_UPDATE` (caminho). Sai 1 se a chave faltar.

- [ ] **Step 1: Escrever `test-appcast.sh`:** gera uma chave descartável com `generate_keys` num keychain temporário (ou, sem a ferramenta, com `SPARKLE_SIGN_UPDATE` apontando para um stub que imprime uma assinatura fixa); roda `appcast.sh` sobre um DMG fictício e confere no XML: `sparkle:version` = `build-number`, `sparkle:shortVersionString` = versão, `length` = tamanho do arquivo, `url` = `…/releases/download/<tag>/Collie-<v>.dmg`, `sparkle:edSignature` não vazio, `sparkle:minimumSystemVersion` = `LSMinimumSystemVersion` do app; recusa sem a variável da chave e recusa tag inválida.
- [ ] **Step 2: Rodar e ver falhar.**
- [ ] **Step 3: Implementar `appcast.sh`** (um `<item>` por release; o XML é escrito por `printf`/`jq`-free templating; `sign_update` alimentado por stdin com a chave).
- [ ] **Step 4: `release.yml`:** baixar a versão fixada do Sparkle (URL de release do GitHub) e conferir o sha256 pinado; passo "Appcast" com `env: SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}`; `appcast.xml` por último em `ASSETS`; no passo "Conferir manifesto publicado", baixar o `appcast.xml` publicado e conferir que o `length` e a URL batem com o DMG publicado.
- [ ] **Step 5: `docs/release.md`:** seção "Sparkle": o secret, a chave pública no plist, o que fazer se a chave se perder (nova chave exige um build com a pública nova distribuído por fora).
- [ ] **Step 6: Verificar:** `bash scripts/ci/test-appcast.sh`; `actionlint` se disponível, senão revisão do YAML.
- [ ] **Step 7: Commit** `ci(update): signed appcast published last`.

### Task 4: Wrapper do Sparkle no app e adiamento com agente ocupado

**Files:**
- Create: `Sources/CollieApp/SparkleUpdater.swift`
- Modify: `Sources/CollieApp/UpdatePreferences.swift` (e `CollieApp.swift` onde o app sobe, para criar o wrapper uma vez)
- Test: `Tests/CollieAppTests/SparkleUpdaterTests.swift`

**Interfaces:**
- Consumes: `UpdateModel.activity(terminals:badges:) -> (open: Int, busy: [String])`; `UpdateInstaller.refusal() async -> AppUpdateSwap.Refusal?`.
- Produces: `@MainActor final class SparkleUpdater: NSObject, SPUUpdaterDelegate, ObservableObject` com
  `init(busy: @escaping @MainActor () -> [String], disabled: Bool)`, `var canCheck: Bool`, `func checkNow()`,
  `var automaticChecks: Bool { get set }` e `static func shouldPostpone(busy: [String]) -> Bool`.

- [ ] **Step 1: Testes** (`SparkleUpdaterTests`): `shouldPostpone(busy: [])` é falso e `shouldPostpone(busy: ["a"])` é verdadeiro; com `disabled: true` o wrapper não cria o controller (`canCheck` falso, `checkNow()` não faz nada); a mensagem do aviso (texto puro em `UpdateModel`, ao lado de `sheet`) lista os agentes ocupados no singular/plural como `UpdateModel.sheet` já faz.
- [ ] **Step 2: Rodar `swift test --filter SparkleUpdaterTests` e ver falhar.**
- [ ] **Step 3: Implementar `SparkleUpdater`:** cria `SPUStandardUpdaterController(startingUpdater: !disabled, updaterDelegate: self, userDriverDelegate: nil)`; no delegate, `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` devolve `shouldPostpone(busy: busy())`, guarda o bloco e mostra um alerta com "Atualizar mesmo assim" (chama o bloco) / "Depois" (mantém o bloco; reabre quando `busy()` ficar vazio ou o dono pedir de novo). `disabled` = build local (`refusal() != nil`).
- [ ] **Step 4: `UpdatePreferences`:** trocar o cartão de download/instalação próprio por: versão instalada, "Verificar agora" (`checkNow()`), interruptor "Verificar sozinho" (`automaticChecks`), e a nota de build local já existente. O código do instalador próprio (`UpdateInstallSheet`, troca por rename) deixa de ser alcançado pela UI; **não** apagar os arquivos neste plano (spec §8).
- [ ] **Step 5: Verificar:** `swift test --filter SparkleUpdaterTests` passa; `swift build --product CollieApp` compila.
- [ ] **Step 6: Commit** `feat(update): Sparkle drives Preferences › Atualizações, relaunch waits for busy agents`.

### Task 5: Documentação e CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (`[Unreleased]`, **Changed**), `docs/release.md`, `docs/superpowers/specs/2026-11-17-update-downloader-design.md` (cabeçalho: "instalação substituída pelo Sparkle, ver 2026-11-25")

- [ ] **Step 1:** CHANGELOG: o app se atualiza pelo Sparkle (instalação com senha ou "Install with privilege management"); 0.2.x chegam à primeira versão com Sparkle pelo caminho antigo; build local não se atualiza.
- [ ] **Step 2:** apontar no `docs/release.md` o roteiro manual (spec "Validação"): troca entre duas versões com Sparkle, pedido de senha, PID do `collied` sobrevive, aviso de agente ocupado.
- [ ] **Step 3: Commit** `docs(update): Sparkle, CHANGELOG and manual script`.

## Fora deste plano (passos do dono)

1. Aprovar este plano e a spec.
2. Depois do merge: publicar uma versão com Sparkle, instalar, e publicar uma seguinte para ver a atualização (roteiro manual, itens 2 e 3 da spec).
3. Se `collied` cair na troca, reabrir o ponto do delegate antes de recomendar (risco principal da spec).
