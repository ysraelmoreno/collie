# Release assinado (Developer ID + notarização)

Só para distribuir a outros Macs. Uso local: `scripts/bundle-app.sh` (identidade `Collie Local`).

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
que já existe). Nunca roda em pull request. Runner `macos-26` (arm64, Xcode 26). Ele regera o `vendor/` (o figcraft
fica em cache pelo hash de `scripts/build-figcraft.sh` e `patches/figcraft/`; sem cache leva 20 a 40 min), assina num
keychain temporário, notariza com a API key, e cria a GitHub Release da tag com `Collie-<versão>.dmg` e
`Collie-<versão>.dmg.sha256`, mais as cópias idênticas `Collie.dmg` e `Collie.dmg.sha256`: o asset `Collie.dmg`
existe para o link estável <https://github.com/ysraelmoreno/collie/releases/latest/download/Collie.dmg> (site). Se a
release já existe, só troca esses arquivos. O keychain e as chaves são
apagados no fim, mesmo com falha.

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
