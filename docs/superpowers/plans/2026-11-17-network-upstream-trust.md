# CAs do macOS para o destino no painel Rede Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cada `mitmdump` do painel Rede sobe (attach e restart) com `--set ssl_verify_upstream_trusted_ca=<pacote>`,
um PEM com as CAs em que o macOS confia, salvo quando o `config.yaml` do usuário decide; falha ao montar nunca
impede o Interceptar.

**Architecture:** `UpstreamTrust` (CollieDaemonKit/Network) tem a regra pura (snapshot → PEM), a escrita atômica, a
leitura tolerante do `config.yaml` e a fonte real (Security.framework). `MitmProcess.start` recebe uma closure
`upstreamCA` chamada em todo `startOnce`, então o `restarted()` remonta sozinho. `NetworkProxy` expõe o resultado e o
`network.status` o mostra por sessão.

**Tech Stack:** Swift 6.2 (CollieDaemonKit), Security.framework (`SecTrustCopyAnchorCertificates`,
`SecTrustSettingsCopyCertificates`, `SecTrustSettingsCopyTrustSettings`), Swift Testing, mitmproxy 12.3.1.

**Spec:** `docs/superpowers/specs/2026-11-17-network-upstream-trust-design.md`

## Global Constraints

- **A Task 0 (roteiro do dono) vem antes de tudo.** Se ela escolher B′ (avaliação pelo trustd), pare: a Task 1 muda
  (a regra pura cai, a fonte devolve a lista avaliada) e o plano precisa ser revisto. Sem resultado da Task 0, as
  Tasks 1–3 seguem com B, que é o padrão recomendado.
- Testes: só os criados ou alterados, `swift test --disable-sandbox --scratch-path <tmp>/.build --filter <Suite>`
  numa worktree `git worktree add --detach <tmp> HEAD` (removida no fim). **Nunca** a suíte inteira.
- **O executor NÃO deve**: instalar, abrir ou reiniciar o app; rodar `scripts/bundle-app.sh`, `scripts/release.sh`
  ou `scripts/dev/reload.sh`; tocar no daemon ou no app reais do dono (`launchctl`, `dev.collie.daemon`,
  `~/Library/Application Support/Collie`); dar push; disparar workflow; editar `scripts/` ou `.github/`; ler ou
  escrever no Keychain real nos testes; rodar o `mitmdump` contra a rede (só o E2E opcional da Task 4, em loopback);
  mudar trust settings (`security add-trusted-cert`, `trust-settings-import`).
- Commit por task, só dos seus arquivos (`git diff <arquivo>` antes de `git add`). Trailer
  `Co-Authored-By: <seu modelo real> <noreply@anthropic.com>`. Não editar `.collie/`.
- Valores do spec:
  - Pacote: `<root>/network/upstream-ca.pem`; escrita atômica (temp no mesmo diretório + rename), só quando os bytes
    mudam; **nunca apagado** pelo daemon.
  - Opção passada: `--set ssl_verify_upstream_trusted_ca=<path>`. Nunca `ssl_insecure`.
  - Chaves que fazem o usuário decidir (no `config.yaml`, chave de topo na coluna 0): `ssl_verify_upstream_trusted_ca`,
    `ssl_verify_upstream_trusted_confdir`, `ssl_insecure: true`. `ssl_insecure: false` não conta.
  - Modos: `system` (com `certs`), `user-config`, `unavailable` (com `reason`).
  - Política SSL da Apple: OID `1.2.840.113635.100.1.3`. Resultados: `1` TrustRoot, `2` TrustAsRoot, `3` Deny,
    `4` Unspecified; ausente conta como `1`.
  - Log: uma linha em `FileHandle.standardError` (modelo `DataBackup.swift:344`), só modo, contagem e motivo; sem PEM
    nem nomes de certificado.
- Se o plano não bater com o código, pare e pergunte.

## Review Focus

- `mitmdump` morre e o poller o reinicia: o pacote é remontado e o `config.yaml` relido (Task 3,
  `e2eRestartResolvesAgain`; sem E2E, a revisão confere que `restarted` repassa a closure).
- A fonte falha depois de uma subida que funcionou: o arquivo antigo fica (outra sessão pode lê-lo tarde), o modo é
  `unavailable` e não se passa `--set` (Task 2, `failureKeepsExistingFile`).
- `config.yaml` é FIFO, diretório, symlink ou gigante: não bloqueia nem trava o daemon; conta como "não decide" (Task
  2, `configYamlNotRegularIsIgnored`, `configYamlOver64KiBIsIgnored`).
- Zero certificados no snapshot: nada é escrito, `unavailable` (Task 2, `emptySnapshotIsUnavailable`).
- Dois emuladores sobem ao mesmo tempo com o mesmo conteúdo: a segunda escrita não troca o arquivo (Task 1,
  `unchangedWriteKeepsInode`).

## File Structure

- Create `Sources/CollieDaemonKit/Network/UpstreamTrust.swift`: tipos do snapshot, regra, PEM, escrita, fonte real,
  leitura do `config.yaml`, `resolve`.
- Modify `Sources/CollieDaemonKit/Network/MitmProcess.swift` (`args`, `start`, `startOnce`, `restarted`).
- Modify `Sources/CollieDaemonKit/Network/NetworkService.swift` (`NetworkProxy`, `status`, `init(root:…)`).
- Test: `Tests/CollieDaemonKitTests/UpstreamTrustTests.swift` (novo), `NetworkMitmTests.swift`,
  `NetworkServiceTests.swift` (`FakeProxy`).

## Ordem e dependências

- Task 0 (dono) antes de tudo. Task 1 independente. Task 2 depende de 1. Task 3 (E2E opcional) depende de 2.
- Ordem: 0 → 1 → 2 → 3.

---

### Task 0: Validação na máquina corporativa — passo do dono, não do executor

Ver "Roteiro manual do dono", parte A. Resultado: B ou B′, anotado no spec ("Minhas chamadas").

---

### Task 1: `UpstreamTrust` — regra, PEM e escrita

**Files:**
- Create: `Sources/CollieDaemonKit/Network/UpstreamTrust.swift`
- Test: `Tests/CollieDaemonKitTests/UpstreamTrustTests.swift`

**Interfaces:**
- Produces:
  - `struct TrustSetting: Sendable, Equatable { var result: Int?; var policyOID: String?; var policyString: String? }`
  - `struct TrustEntry: Sendable, Equatable { var der: Data; var selfSigned: Bool; var settings: [TrustSetting] }`
  - `struct TrustSnapshot: Sendable, Equatable { var anchors: [Data]; var admin: [TrustEntry]; var user: [TrustEntry] }`
  - `enum UpstreamTrust { static let sslOID = "1.2.840.113635.100.1.3" }`
  - `static func bundle(_ s: TrustSnapshot) -> (pem: String, count: Int, denied: Int)`
  - `static func write(_ pem: String, to url: URL) throws -> Bool` (true se trocou o arquivo)
  - `static func systemSnapshot() throws -> TrustSnapshot` (fonte real; nunca chamada nos testes)

Os DER dos testes são bytes quaisquer (`Data("a".utf8)`): a regra não interpreta o certificado.

- [ ] **Step 1: Write the failing tests**: `anchorIn`; `adminEmptySettingsIn`; `trustRootSelfSignedIn`;
  `trustRootNotSelfSignedOut`; `trustAsRootNotSelfSignedIn`; `trustAsRootSelfSignedOut`; `missingResultIsTrustRoot`;
  `policyStringOut` (`TrustSetting(result: 1, policyOID: sslOID, policyString: "a.example")`);
  `nonSSLPolicyOut` (OID de Code Signing `1.2.840.113635.100.1.16`); `unspecifiedOut` (4); `denyOut` e
  `denyRemovesAnchor` (mesmo DER nas âncoras e com `3` no user → fora, `denied == 1`); `dedupeByDER` (mesmo DER
  nas âncoras e no admin → `count == 1`); `pemFormat` (cada bloco `-----BEGIN CERTIFICATE-----`, base64 em linhas
  de 64, `-----END CERTIFICATE-----`); `emptySnapshotCountsZero` (`count == 0`, `pem` vazio); `writeReplacesWhenChanged`; `unchangedWriteKeepsInode` (segunda `write` igual →
  `false`, mesmo `fileSystemFileNumber`). Caso real (Task 0) como fixture **só de forma**, sem certificado: `tlsproxyRootIn` (raiz autoassinada
  com o Policy/Result que a Task 0 anotar → entra) e `tlsproxyIntermediateTrustRootOut` (não autoassinada, `TrustRoot`
  → fora); se a Task 0 ainda não voltou, use settings vazias para a raiz e marque o teste com o comentário
  `// ponytail: ajustar à tabela da Task 0`.
- [ ] **Step 2: Run** `--filter UpstreamTrustTests`. Expected: FAIL (tipos não existem).
- [ ] **Step 3: Implement** `bundle` e `write`. Um item vale se `(policyOID == nil || policyOID == sslOID) &&
  policyString == nil` e `(result ?? 1) == 1 && selfSigned || result == 2 && !selfSigned`; lista vazia vale; `Deny`
  em qualquer item de admin/user tira o DER do resultado inteiro, âncoras inclusive. Ordem estável (âncoras, admin,
  user). `systemSnapshot`: `selfSigned` comparando `SecCertificateCopyNormalizedSubjectSequence` com
  `…IssuerSequence`; política lida por `SecPolicyCopyProperties`/`kSecPolicyOid`; domínio sem certificados
  (`errSecNoTrustSettings`) é lista vazia, não erro.
- [ ] **Step 4: Run** `--filter UpstreamTrustTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(network): macOS trust bundle for upstream verification`.

### Task 2: Subida, args, `config.yaml` e status

**Files:**
- Modify: `Sources/CollieDaemonKit/Network/UpstreamTrust.swift`, `Sources/CollieDaemonKit/Network/MitmProcess.swift:41-116`,
  `Sources/CollieDaemonKit/Network/NetworkService.swift:6-18, 83-97, 175-186`
- Test: `Tests/CollieDaemonKitTests/UpstreamTrustTests.swift`, `Tests/CollieDaemonKitTests/NetworkMitmTests.swift`,
  `Tests/CollieDaemonKitTests/NetworkServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 (`TrustSnapshot`, `bundle`, `write`, `systemSnapshot`).
- Produces:
  - `struct UpstreamCA: Sendable, Equatable { enum Mode: String, Sendable { case system, userConfig = "user-config", unavailable }; var url: URL?; var mode: Mode; var certs: Int?; var reason: String? }`
    e `static let none = UpstreamCA(url: nil, mode: .unavailable, certs: nil, reason: "not configured")`
  - `static func userConfigDecides(confdir: URL) -> Bool` (em `UpstreamTrust`)
  - `static func resolve(confdir: URL, out: URL, snapshot: () throws -> TrustSnapshot, log: (String) -> Void) -> UpstreamCA`
  - `MitmProcess.args(port:confdir:addon:rules:upstreamCA: URL? = nil)`
  - `MitmProcess.start(…, upstreamCA: @escaping @Sendable () -> UpstreamCA = { .none })`; `var upstreamCA: UpstreamCA`
  - `protocol NetworkProxy { var upstreamCA: UpstreamCA { get } }`

- [ ] **Step 1: Write the failing tests**:
  - `UpstreamTrustTests`: `configDecidesCA`, `configDecidesConfdir`, `configDecidesInsecureTrue`
    (cada um → `resolve` devolve `.userConfig`, `url == nil`, snapshot **não** chamado);
    `insecureFalseDoesNotDecide` (→ `.system`); `commentedOrIndentedKeyIgnored` (`# ssl_insecure: true`,
    `  ssl_verify_upstream_trusted_ca: x`); `quotedKeyIsEstimate` (`"ssl_insecure": true` → `.system`, documenta o
    limite); `configYamlNotRegularIsIgnored` (diretório e FIFO em `config.yaml` → retorna sem bloquear, `.system`);
    `configYamlOver64KiBIsIgnored`; `insecureTrueLogs` (o `log` recebe uma linha com `ssl_insecure`);
    `resolveWritesAndReturnsSystem` (`url == out`, `certs == count`); `emptySnapshotIsUnavailable` (nada escrito);
    `failureKeepsExistingFile` (arquivo pré-existente; snapshot lança → `.unavailable`, `url == nil`, arquivo intacto,
    `log` chamado, sem nomes nem PEM na linha).
  - `NetworkMitmTests`: `argsWithUpstreamCA` (termina em `"--set", "ssl_verify_upstream_trusted_ca=/c/up.pem"`);
    o teste de args existente (`NetworkMitmTests.swift:33-40`) continua igual sem o parâmetro; nenhum arg contém
    `ssl_insecure`.
  - `NetworkServiceTests`: `FakeProxy` ganha `upstreamCA`; `statusShowsUpstreamCA` (com sessão: `upstreamCA:
    "system"`, `certs`); `statusWithoutSessionHasNoUpstreamCA`.
- [ ] **Step 2: Run** `--filter UpstreamTrustTests`, `--filter NetworkMitmTests`, `--filter NetworkServiceTests`.
  Expected: FAIL.
- [ ] **Step 3: Implement**. `userConfigDecides`: `lstat` antes de abrir; só arquivo regular ≤ 64 KiB, aberto com
  `O_NONBLOCK | O_NOFOLLOW`; linha casa `^(ssl_verify_upstream_trusted_ca|ssl_verify_upstream_trusted_confdir)\s*:`
  ou `^ssl_insecure\s*:\s*(true|yes|on)\s*(#.*)?$` (sem diferenciar maiúsculas no valor). `resolve` escreve o pacote
  **antes** de devolver a URL. `startOnce` chama a closure, guarda o resultado e passa `url` a `args`; `restarted`
  repassa a mesma closure. `init(root:…)` passa `{ UpstreamTrust.resolve(confdir: confdir, out:
  root.appendingPathComponent("network/upstream-ca.pem"), snapshot: UpstreamTrust.systemSnapshot, log: { … stderr … }) }`
  (fiação sem teste próprio: a fonte real não roda em teste). `status` acrescenta `upstreamCA` (`mode.rawValue`) e
  `certs` quando houver.
- [ ] **Step 4: Run** os três filtros. Expected: PASS.
- [ ] **Step 5: Commit** `feat(network): pass the macOS trust bundle to mitmdump on every start`.

### Task 3 (opcional): E2E com `mitmdump` real em loopback

**Files:**
- Test: `Tests/CollieDaemonKitTests/NetworkMitmTests.swift`

**Interfaces:**
- Consumes: Task 2 (`MitmProcess.start(…, upstreamCA:)`).

- [ ] **Step 1: Write the tests**, todos com `.enabled(if: COLLIE_E2E_MITM != nil && MitmTool.locate(…) != nil)`, no
  molde de `realMitmdumpStartsAndStops`, tudo em `/tmp/collie-mitm-<uuid>` removido no fim. Fixture: CA de teste e
  certificado de servidor com SAN `IP:127.0.0.1` gerados com `/usr/bin/openssl`; servidor
  `/usr/bin/openssl s_server -www -accept <porta livre> -cert … -key … -CAfile …`; pedido por
  `/usr/bin/curl --proxy http://127.0.0.1:<p> --cacert <confdir>/mitmproxy-ca-cert.pem https://127.0.0.1:<porta>/`.
  - `e2eTrustedBundleGives200`: `upstreamCA` com o PEM da CA de teste → HTTP 200.
  - `e2eWithoutBundleFailsVerify`: closure `.none` → 502 e uma linha `error` com `Certificate verify failed`.
  - `e2eUserConfigWins`: `config.yaml` com `ssl_verify_upstream_trusted_ca: <PEM vazio de CA alheia>` + closure com o
    pacote bom → 502 (o arquivo vence o `--set`).
  - `e2eRestartResolvesAgain`: closure com contador; `start` + `restarted()` → chamada 2×.
- [ ] **Step 2: Run** `COLLIE_E2E_MITM=1 swift test … --filter NetworkMitmTests`. Expected: PASS; sem a variável, os
  quatro são pulados.
- [ ] **Step 3: Commit** `test(network): loopback e2e for upstream trust`.

---

## Roteiro manual do dono (não é tarefa de executor)

Tudo só leitura; nada muda trust settings nem o Keychain.

**A. Antes de implementar (Task 0), na máquina corporativa:**

Já sabido: o inspetor é o TLSProxy; `ca.example.com` e `eproxy.ca.example.com` aparecem em
`security dump-trust-settings` (domínio não confirmado). Falta o resto:

1. Em qual domínio e com que Policy/Result:
   - `security dump-trust-settings -d | grep -i -A12 tlsproxy` (admin; sem sudo)
   - `security dump-trust-settings | grep -i -A12 tlsproxy` (user)
   - Anotar, por certificado: domínio, `Policy OID` (ou "nenhuma"), `Result` (ou ausente), `Policy String` se houver.
2. Quem é autoassinado (subject == issuer):
   - `security find-certificate -a -c "tlsproxy" -p /Library/Keychains/System.keychain ~/Library/Keychains/login.keychain-db | awk '/BEGIN/{n++} {print > ("ns" n ".pem")}' && for f in ns*.pem; do openssl x509 -in $f -noout -subject -issuer; done`
   - `profiles list` e `system_profiler SPConfigurationProfileDataType | grep -i -B2 -A6 certificate` (veio por MDM?)
   - Nada disso é commitado; só os nomes e o par (Policy, Result, autoassinado) voltam para o spec.
3. Protótipo B e B′ (arquivo temporário fora do repo; `NOME = "tlsproxy"`):

   ```swift
   import Foundation; import Security
   let NOME = "<nome da CA>"
   func name(_ c: SecCertificate) -> String { (SecCertificateCopySubjectSummary(c) as String?) ?? "?" }
   var a: CFArray?; SecTrustCopyAnchorCertificates(&a)
   var b = ((a as? [SecCertificate]) ?? []).map(name)
   for d in [SecTrustSettingsDomain.admin, .user] {
       var cs: CFArray?; SecTrustSettingsCopyCertificates(d, &cs); b += ((cs as? [SecCertificate]) ?? []).map(name)
   }
   print("B contém a CA:", b.contains { $0.contains(NOME) })
   var r: CFTypeRef?
   SecItemCopyMatching([kSecClass: kSecClassCertificate, kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true] as CFDictionary, &r)
   for c in (r as? [SecCertificate]) ?? [] where name(c).contains(NOME) {
       for (p, pol) in [("SSL", SecPolicyCreateSSL(true, nil)), ("X509", SecPolicyCreateBasicX509())] {
           var t: SecTrust?; SecTrustCreateWithCertificates(c, pol, &t)
           var e: CFError?; print("B′", p, name(c), SecTrustEvaluateWithError(t!, &e), e.map { "\($0)" } ?? "")
       }
   }
   ```
   `swiftc -O proto.swift -o proto && ./proto`. Conferir que **nenhum diálogo** de keychain aparece.
   O "B contém" do protótipo é só presença; a regra completa é a do passo 1 aplicada à tabela: a raiz
   `ca.example.com` tem de sair "entra" (autoassinada com `TrustRoot`/ausente, ou settings vazias, sem
   `Policy String`, política nenhuma ou SSL).
4. Decisão: a raiz do TLSProxy entra pela regra → B (padrão). Só B′ a aceita → B′, e o plano volta para revisão.
   Nenhum → anotar e parar.

**B. Depois das Tasks 1–2, na máquina corporativa** (com o app do dono atualizado pelo caminho normal dele):

1. Guardar e tirar o `config.yaml` manual: `mv "<root>/network/mitm/config.yaml" ~/config.yaml.bak`.
2. Interceptar o emulador; `collie network status` mostra `upstreamCA: system` e `certs`; os pedidos voltam 200.
3. Nenhum diálogo de keychain na subida nem no restart (matar o `mitmdump` e esperar o poller).
4. Pôr o `config.yaml` de volta: `upstreamCA: user-config`, e continua 200.
