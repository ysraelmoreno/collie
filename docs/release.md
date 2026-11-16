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
