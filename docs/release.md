# Release assinado (Developer ID + notarização)

Só para distribuir a outros Macs. Uso local: `scripts/bundle-app.sh` (identidade `Collie Local`).

## Versionamento

A versão vem da tag anotada `vX.Y.Z` (não há arquivo de versão). Enquanto estivermos antes do 1.0, a regra é SemVer com o
sentido abaixo. O número diz ao usuário o tamanho da mudança; ele não é um contador de releases.

| Sobe | Quando | Exemplo |
|---|---|---|
| **Minor** (`0.2.0`, `0.3.0`) | entra funcionalidade nova, ou muda um comportamento que o usuário vê (comando, flag, tela, formato de arquivo) | a Fábrica (`work run --review`, `factory doctor/ratchet/bait/init`) |
| **Patch** (`0.2.1`) | só correção, sem funcionalidade nova e sem mudar comportamento documentado | o conserto de um painel em branco |
| **Major** (`1.0.0`) | quando o dono declarar a API estável (comandos, protocolo, formatos de arquivo) | não antes disso |

- Uma seção **Added** no CHANGELOG sempre pede minor. Se a seção `[Unreleased]` tem **Added**, o próximo número NÃO é um patch.
- **Mudança que quebra** (remove ou renomeia comando, flag ou campo de arquivo; muda formato) antes do 1.0 também sobe o minor e vai
  em **Changed** com a palavra "quebra", com o caminho de migração.
- **Preview:** uma funcionalidade grande que ainda não foi validada em projeto real entra marcada "(preview)" no CHANGELOG e na
  nota da release; ela pode mudar entre minors sem aviso de migração. Tirar o "preview" é decisão do dono, depois da validação.
- **Esquemas de arquivo têm versão própria**, independente da do app: `collie-work.json` e o perfil `factory` (`"version": 1`) mudam
  de versão só quando o formato muda de forma incompatível. O CHANGELOG cita as duas quando for o caso.
- Antes da tag: a seção `[Unreleased]` vira `[X.Y.Z] — data`, o número segue a tabela acima (confira o **Added**), a varredura de
  segredos passa e o push da `main` vai sem force. Tag e release são sempre do dono.

## Uma vez só

1. Apple Developer Program ativo (US$ 99/ano): <https://developer.apple.com/programs/>.
2. Certificado **Developer ID Application** (só o Account Holder cria):
   - Xcode: Settings > Accounts > seu time > **Manage Certificates** > **+** > **Developer ID Application**; ou
   - Portal: <https://developer.apple.com/account/resources/certificates/list> > **+** > *Developer ID Application*
     (pede um CSR: Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority > Saved to disk).
   - Confira: `security find-identity -v -p codesigning` lista `Developer ID Application: Seu Nome (TEAMID)`.
3. Senha específica de app em <https://account.apple.com> > Sign-In and Security > App-Specific Passwords, e guarde:
   `xcrun notarytool store-credentials collie-notary --apple-id <seu-apple-id> --team-id <TEAMID> --password <senha-de-app>`

## Cada release

```
scripts/release.sh          # gera build/Collie-<versão>.dmg assinado, notarizado e com ticket
```

- **DMG** (`scripts/make-dmg.sh <Collie.app> <out.dmg>`, chamado pelo `release.sh`): usa o `dmgbuild` (Python), que
  escreve o `.DS_Store` direto; não depende do Finder, então roda em terminal sandboxed e no CI. Instale antes:
  `python3 -m pip install -r scripts/dmg-requirements.txt` (versões exatas; sem `dmgbuild` o script falha com essa
  linha; `COLLIE_DMG_PYTHON` escolhe outro Python, ex. um venv). O `release.yml` instala do mesmo arquivo. Tamanho da
  janela (660x420), posições dos ícones e fundo ficam só em `scripts/dmg-settings.py` (`ICON_Y`, `APP_X`,
  `APPLICATIONS_X`): ajuste lá olhando um screenshot da janela. No fim o script monta o dmg só leitura, lê o
  `.DS_Store` e falha se faltar a posição dos dois ícones ou a imagem de fundo (não confere o desenho, só os dados).
- `COLLIE_SKIP_NOTARIZE=1` assina e gera o dmg sem enviar à Apple.
- A versão vem de `CFBundleShortVersionString` em `Resources/Info.plist`.
- Gere a partir da `main` (mesma regra do bundle).
- `COLLIE_VERSION=0.2.0` (ou `v0.2.0`) troca a versão só no app gerado, sem mexer no plist do git.
- A notarização não usa `--wait`: o script consulta `notarytool info` a cada minuto, por até `COLLIE_NOTARY_TIMEOUT`
  segundos (padrão 14400 = 4 h). Falha de rede numa consulta não derruba a espera.
- Credenciais por variáveis (sem perfil do keychain), como no CI:
  `COLLIE_NOTARY_KEY=<caminho do AuthKey_XXXX.p8> COLLIE_NOTARY_KEY_ID=<key id> COLLIE_NOTARY_ISSUER=<issuer id>`.

## Pelo GitHub Actions

`.github/workflows/release.yml` roda num push de tag `v*` ou à mão (Actions > release > Run workflow, com uma tag
que já existe). Nunca roda em pull request. Runner `macos-26` (arm64, Xcode 26), limite de 270 min. Primeiro o passo
**Conferir motor** baixa o motor de design fixado no pin, confere `sha256`, `size` e a assinatura (seção abaixo) e
falha se ele não estiver publicado; depois regera o `vendor/` (sem figcraft: o dmg não traz o motor e
`scripts/release.sh` falha se `Contents/Resources/figcraft` existir), assina num keychain temporário
(`scripts/ci/signing-keychain.sh`), notariza com a API key, e cria a GitHub Release da tag com `Collie-<versão>.dmg` e
`Collie-<versão>.dmg.sha256`, mais as cópias idênticas `Collie.dmg` e `Collie.dmg.sha256`: o asset `Collie.dmg`
existe para o link estável <https://github.com/ysraelmoreno/collie/releases/latest/download/Collie.dmg> (site), e o
`update.json` (seção abaixo). Se a release já está **publicada**, só troca esses arquivos (`--clobber`); um draft da
mesma tag que sobrou de uma rodada que caiu é apagado antes de criar a release de novo. A release nova só vira a
"latest" do GitHub se a tag é a maior `vX.Y.Z` publicada (um hotfix numa linha antiga sai com `--latest=false`). O
keychain e as chaves são apagados no fim, mesmo com falha.

```
git tag v0.2.0 && git push origin v0.2.0
```

### Secrets (Settings > Secrets and variables > Actions > Repository secrets)

| Secret | Conteúdo |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `.p12` do certificado Developer ID Application **com a chave privada**, em base64 |
| `DEVELOPER_ID_P12_PASSWORD` | senha escolhida ao exportar o `.p12` |
| `NOTARY_API_KEY_P8` | conteúdo do `AuthKey_XXXX.p8` (texto, com as linhas BEGIN/END) |
| `NOTARY_API_KEY_ID` | Key ID da chave (10 caracteres) |
| `NOTARY_API_ISSUER_ID` | Issuer ID (UUID) da página de chaves |

Como criar (só o dono da conta; nada disso vai para o git nem para outra pessoa):

1. **`.p12`**: Keychain Access > login > My Certificates > abra a seta de
   `Developer ID Application: Seu Nome (TEAMID)` e selecione o certificado **e** a chave > botão direito >
   Export 2 items… > formato `.p12` > defina uma senha forte. Depois:
   ```
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 -R ysraelmoreno/collie
   gh secret set DEVELOPER_ID_P12_PASSWORD -R ysraelmoreno/collie   # cola a senha no prompt
   rm DeveloperID.p12
   ```
2. **API key**: <https://appstoreconnect.apple.com/access/integrations/api> > Team Keys > **+** > nome `collie-ci`,
   acesso **Developer** (basta para notarizar) > Generate. Baixe o `.p8` (só dá para baixar uma vez). Anote o
   **Key ID** da linha e o **Issuer ID** do topo da página.
   ```
   gh secret set NOTARY_API_KEY_P8 -R ysraelmoreno/collie < AuthKey_XXXX.p8
   gh secret set NOTARY_API_KEY_ID -R ysraelmoreno/collie
   gh secret set NOTARY_API_ISSUER_ID -R ysraelmoreno/collie
   ```
   Guarde o `.p8` num lugar seguro ou apague: se vazar, revogue a chave na mesma página.

Se a notarização passar de 4 h o job falha com o id da submissão no log; rode de novo pelo Run workflow com a
mesma tag (é uma submissão nova).

## Manifesto de atualização (`update.json`)

O atualizador do app lê `https://github.com/ysraelmoreno/collie/releases/latest/download/update.json` (até 64 KB) e
monta a URL do dmg a partir da `tag` e do `dmg` (`…/releases/download/<tag>/Collie-<versão>.dmg`). O passo
**Manifesto** do `release.yml` roda depois de `scripts/release.sh` (dmg já notarizado e grampeado:
`xcrun stapler validate` antes) e chama `scripts/ci/update-manifest.sh <tag> build/Collie-<versão>.dmg
build/Collie.app build/update.json`:

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

- `size`/`sha256`: do dmg final; `minimumSystemVersion`: `LSMinimumSystemVersion` do app gerado (que também tem de
  ter `CFBundleShortVersionString` = versão da tag); `teamId`: `TeamIdentifier=` do `codesign -dv` do app, igual ao
  `teamId` do pin; `figcraftEngine`: `version` do pin que vai no app (`Contents/Resources/figcraft-engine.json`).
- O script recusa tag fora de `vX.Y.Z`, dmg com outro nome, app sem time e `size` fora de (0, 500 MB].
  Teste offline: `scripts/ci/test-update-manifest.sh`.
- Depois de publicar, o passo **Conferir manifesto publicado** baixa `…/releases/download/<tag>/update.json` (nunca
  `latest`, que na rodada de uma tag antiga aponta para outra release), compara com o gerado e confere `size` e
  `sha256` contra o dmg publicado.
- Release sem `update.json` (as anteriores a isto): o app trata como "nada novo".
- `requiresServiceRestart: true` (opcional, não gerado hoje) só entra à mão quando uma versão quebrar a
  compatibilidade do daemon antigo com o app novo.

### Testar com outra fonte (`COLLIE_UPDATE_MANIFEST`)

O daemon (`collied`) lê `COLLIE_UPDATE_MANIFEST` em qualquer build, só com `file://` (outro esquema é ignorado, com
log); a página Atualizações mostra "fonte de teste: <url>". O dmg continua tendo de ser do time e notarizado. Use
sempre numa **conta de usuário macOS separada**, nunca no daemon do dia a dia:

```
launchctl setenv COLLIE_UPDATE_MANIFEST file:///Users/teste/update.json   # depois reinicie o serviço dessa conta
launchctl unsetenv COLLIE_UPDATE_MANIFEST                                 # volta ao GitHub (reinicie de novo)
```

### Voltar para a versão anterior

Depois de uma troca, o app anterior fica guardado em `.Collie-update-XXXXXX/Collie.app`, na mesma pasta do app
(`/Applications` ou `~/Applications`), até a segunda abertura saudável da versão nova. Enquanto isso, Preferências ›
Atualizações mostra **Voltar para <versão>**. Se o app novo nem abre, pelo Terminal (troque `/Applications` pela
pasta onde o Collie está):

```
osascript -e 'quit app "Collie"'
ls -d /Applications/.Collie-update-*/Collie.app                     # se houver mais de uma, use a mais nova
P="$(ls -td /Applications/.Collie-update-*/Collie.app | head -1)"
codesign --verify --deep --strict "$P" && defaults read "$P/Contents/Info" CFBundleShortVersionString
mv /Applications/Collie.app "/Applications/Collie-quebrado.app"
mv "$P" /Applications/Collie.app
open /Applications/Collie.app
```

Depois, apague `/Applications/Collie-quebrado.app` e a pasta `.Collie-update-*` que ficou vazia.

## Motor de design (figcraft)

O motor do painel Design é um download à parte, fixado por `Resources/figcraft-engine.json` (o pin: versão, URL,
tamanhos, sha256 e team ID). `.github/workflows/figcraft.yml` o publica numa release própria `figcraft-v<versão>`
(`--prerelease --latest=false`: nunca vira a "latest", o link do `Collie.dmg` continua). Roda num push na `main` que
mexe nos insumos ou no pin, ou à mão (Actions > figcraft > Run workflow). Mesmos secrets da tabela acima; nunca roda
em pull request.

- **Insumos**: `scripts/figcraft-inputs.sh` imprime o hash de `scripts/build-figcraft.sh`,
  `scripts/package-figcraft.sh`, `scripts/figcraft-inputs.sh`, `.github/workflows/figcraft.yml` e
  `patches/figcraft/*.patch`. Mudou qualquer um (até um comentário no workflow): suba o `-c<N>` da `version` e da
  `url` do pin, ponha a saída do script em `inputs` e zere `sha256`/`size`/`unpackedSize`. O workflow e o teste
  `FigcraftPinInputsTests` recusam um `inputs` que não bate.
- **Release já publicada**: o workflow só confere que `sha256` e `size` do pin batem com o asset publicado (pin com
  zeros: imprime os valores e abre o PR do pin, abaixo). Uma versão publicada nunca é refeita (tar, gzip e `--timestamp` não são
  reproduzíveis); nunca apague uma tag `figcraft-v*`.
- **Não publicada**: build do figcraft a frio (cache só das ferramentas e do registry do cargo), keychain temporário
  (`scripts/ci/signing-keychain.sh`, o mesmo do release), `scripts/package-figcraft.sh` assina os dois binários
  (Developer ID, hardened runtime, `--timestamp`, identificadores `figcraft-server`/`figcraft-cli`), notariza o zip
  de `bin/` e gera `build/figcraft-<versão>-arm64.tar.gz` + `.sha256`. A release nasce **draft**, recebe os dois
  arquivos, o asset baixado é conferido e só então ela é publicada. Draft que sobrou de uma rodada que caiu é
  apagado na rodada seguinte.
- **Depois da primeira publicação: PR do pin**. Se o pin está zerado (ou difere do asset recém-publicado), o
  workflow abre um pull request `figcraft-pin-<versão>` que muda só `sha256`, `size` e `unpackedSize` de
  `Resources/figcraft-engine.json` (resto do JSON e formato iguais; `scripts/ci/update-pin.sh`, teste offline em
  `scripts/ci/test-update-pin.sh`). Os valores vêm só do asset que a própria rodada baixou e conferiu: o do draft,
  antes de publicar, ou o da release já publicada quando o pin está zerado; nunca de entrada externa. Branch e commit
  saem pela API com o `GITHUB_TOKEN` (`scripts/ci/pin-pr.sh`; o checkout tem `persist-credentials: false`, nada de
  `git push`); se já há PR aberto desse branch, ele é atualizado, não duplicado. Corpo em pt-BR com run id, tag e
  sha256. Ninguém aprova nem mergeia automaticamente: revise e mergeie. O merge toca o pin, que dispara o
  figcraft de novo; essa rodada acha a release publicada, confere `sha256`/`size` do pin e sai verde, sem PR.
  - **Uma vez**: Settings > Actions > General > Workflow permissions > marque **Allow GitHub Actions to create and
    approve pull requests** (só o dono liga; o workflow nunca aprova). O job pede `pull-requests: write`.
  - **Se o repo bloqueia isso** (ou o PR falha por outro motivo): o passo vira um `::warning::` e a release continua
    publicada. Copie os 3 valores do `::notice::` (ou do resumo da rodada) para o pin num PR à mão.
  - O `teamId` do pin é o OU do certificado Developer ID (`security find-identity -v -p codesigning`, o `(TEAMID)`
    do nome).
- **Release do app**: o dmg sai sem o motor (`release.sh` passa `COLLIE_BUNDLE_FIGCRAFT=0` ao `bundle-app.sh`, que
  ainda copia o pin para `Contents/Resources/figcraft-engine.json`); o usuário baixa em Preferências › Desenho e
  sandbox. O "Conferir motor" do `release.yml` baixa a `url` do pin, confere `sha256`/`size` e roda
  `codesign --verify --strict -R=<requisito>` nos dois binários, com o mesmo requisito do `package-figcraft.sh` e do
  app (Developer ID Application, identificador, `subject.OU` = `teamId` do pin). Pin zerado, release ausente ou
  diferente: o release do app falha; publique o motor e preencha o pin **antes** da tag `v*`.
- **Build local** (`scripts/bundle-app.sh`): com `vendor/figcraft` (de `scripts/build-figcraft.sh`) o motor continua
  embutido em `Contents/Resources/figcraft/` e vence o baixado; sem ele, o app fica com o download.
- Local (sem CI): `scripts/build-figcraft.sh`, depois
  `scripts/package-figcraft.sh "Developer ID Application: Seu Nome (TEAMID)"` com as mesmas credenciais de
  notarização do `release.sh` (`COLLIE_SKIP_NOTARIZE=1` só assina e empacota). Ele imprime `sha256=`, `size=` e
  `unpackedSize=`.
