# CAs do macOS para o destino no painel Rede — design

Status: rascunho para aprovação. Nada implementado. Escopo escolhido pelo dono: só o padrão automático. Revisado com
os achados da revisão independente (2026-11-17).

## Intenção e porquê

Numa máquina gerenciada pela empresa, o painel Rede devolveu 502 em todos os pedidos do emulador, com
"Certificate verify failed: self-signed certificate in certificate chain". A rede inspeciona TLS e reassina os
certificados com uma CA corporativa que está no Keychain; o `mitmdump` confia só no pacote próprio (certifi) e
rejeita o **servidor de destino**. A correção manual (exportar todas as CAs dos keychains com
`security find-certificate` para um `.pem` e apontar `ssl_verify_upstream_trusted_ca` no `<confdir>/config.yaml`)
funcionou. O Collie deve fazer isso sozinho.

## Estado atual (verificado no código e no mitmproxy v12.3.1)

1. `confdir = <root>/network/mitm` (`NetworkService.swift:85`), 0700 (`MitmProcess.swift:121-125`), guarda a chave
   da CA do Collie.
2. `MitmProcess.args` (`MitmProcess.swift:41-44`): `--listen-host 127.0.0.1 -p <porta> --set confdir=… --set
   http2=false -q -s <addon>` e `--set collie_rules=…`. Nenhuma opção de TLS para o destino.
3. Toda subida passa por `MitmProcess.start` → `startOnce`; o `restarted()` (`MitmProcess.swift:110-116`) chama
   `start` com os parâmetros guardados, e o poller chega nele por `proxy.restart()` (`NetworkService.swift:336`),
   **sem** passar pela closure `startProxy` (`NetworkService.swift:89-93`).
4. `network.status` lê só a `Session` (`NetworkService.swift:175-186`); sem sessão devolve `attached:false`
   (`NetworkCommands.swift:17-19`).
5. Opções (`mitmdump --options`): `ssl_verify_upstream_trusted_ca` (PEM), `ssl_verify_upstream_trusted_confdir`,
   `ssl_insecure: false`.
6. **O `config.yaml` vence o `--set`**: `tools/main.py:85-91` aplica `opts.set(*args.setoptions, defer=True)` e
   depois `load_paths(<confdir>/config.yaml)`, que sobrescreve o que já estava setado (`optmanager.py:548-561`).
   Só flags dedicadas (`-p`, `--listen-host`) vencem o arquivo.
7. O pacote **substitui** o certifi (`net/tls.py:217-220`: certifi só se `ca_path` e `ca_pemfile` forem os dois
   nulos). O PEM é lido tarde, no primeiro handshake com o destino, por `create_proxy_server_context` com
   `@lru_cache(256)` (`net/tls.py:194-224`); arquivo ausente ou inválido nesse momento dá
   `RuntimeError("Cannot load trusted certificates…")` em toda conexão HTTPS, **sem** voltar ao certifi.
8. A falha de verificação chega ao addon como `error` com `flow.error.msg = "Certificate verify failed: <motivo>"`
   (`proxy/layers/tls.py:310-321`), mesmo com `-q`; o cliente recebe um 502 HTML.
9. O módulo Network não tem logger; o padrão do daemon é `FileHandle.standardError` (`DataBackup.swift:344`).

## Metas

- Ao subir cada `mitmdump` (inclusive no restart), o daemon monta um pacote com as CAs em que o **macOS** confia e o
  passa ao `mitmdump`.
- O `config.yaml` do usuário nunca é sobrescrito nem contrariado (o próprio mitmproxy já garante; é a saída para
  quem não quer o padrão).
- Falha ao montar o pacote nunca impede o Interceptar.

## Anti-metas

- Nunca `ssl_insecure` nem qualquer desligamento da verificação.
- Nunca ler, exportar ou gravar chave privada: só certificados públicos.
- Nunca pedir senha nem senha de keychain; nunca abrir diálogo do sistema.
- Nunca usar a abordagem A (despejar todos os certificados) como fallback: ver Segurança.

## Abordagens consideradas

**Como escolher os certificados**
- A. `security find-certificate -a -p` nos três keychains (a correção manual). Aqui: 154 + 6 + 11 = 171 (o revisor
  contou 177 na mesma máquina; o login keychain varia). Despeja intermediários e certificados sem confiança; um
  agente sandboxed pode gravar no login keychain (`EssentialPaths.swift:22-23`, R12) e passaria a ser confiável.
  Descartada.
- B. **Trust settings** (Security.framework): `SecTrustCopyAnchorCertificates` + `SecTrustSettingsCopyCertificates`
  em admin e user, filtrados por `SecTrustSettingsCopyTrustSettings`. Aqui: 156 únicos (155 âncoras, que já incluem
  os certificados admin/user com trust settings vazias, + 1), ~¼ s, sem sudo nem diálogo. Determinística, regra pura
  testável. Mudar trust settings exige o diálogo do sistema, então um agente não planta confiança. **Não testada na
  máquina corporativa**: uma CA de MDM pode não aparecer nos domínios admin/user (não verificado).
- B′. **Avaliação pelo trustd**: para cada certificado de CA dos keychains (`SecItemCopyMatching`,
  `kSecClassCertificate`), `SecTrustEvaluateWithError` com `SecPolicyCreateSSL`. Cobre MDM e as restrições da Apple
  (data de emissão etc.), como o Go faz desde o 1.18. Riscos não verificados: a política SSL avalia o certificado
  como folha (key usage, basic constraints) e pode recusar CAs legítimas (testar também com
  `SecPolicyCreateBasicX509`); uma chamada ao trustd por certificado; não é função pura.

**Recomendação:** B como padrão **se** a Tarefa 1 mostrar a CA da empresa em `security dump-trust-settings -d` (ou
sem `-d`) e no protótipo B; senão B′. B é mais simples de testar e de explicar; B′ só se B não cobrir o caso real.

**Como passar ao `mitmdump`:** `--set ssl_verify_upstream_trusted_ca=<pacote>` em `MitmProcess.args`. Escrever no
`config.yaml` foi descartado (clobraria o do usuário).

## Design

### 1. Pacote (`UpstreamTrust`, em `CollieDaemonKit/Network`)

- Fonte injetável: `certificates: @Sendable () throws -> TrustSnapshot`, com as âncoras (`[Data]` DER) e, por domínio
  admin/user, `[(der: Data, selfSigned: Bool, settings: [[String: Any]])]`. A real usa o Security.framework; os
  testes passam fixtures. (Se a Tarefa 1 escolher B′, a fonte devolve a lista já avaliada e a regra abaixo cai.)
- Regra B (função pura `bundle(_:) -> (pem: String, count: Int, denied: Int)`), comparada com o Go 1.14
  (`root_cgo_darwin.go`):
  - entra toda âncora de `SecTrustCopyAnchorCertificates` (domínio system mais admin/user com trust settings vazias);
  - um certificado admin/user entra se as trust settings estão vazias ou têm um item que vale para SSL: sem
    `kSecTrustSettingsPolicy` ou com a política SSL, **sem** `kSecTrustSettingsPolicyString` (confiança restrita a um
    host não vira confiança geral), e com resultado `TrustRoot` (ausente conta como `TrustRoot`) **só se
    autoassinado** ou `TrustAsRoot` **só se não autoassinado**;
  - sai qualquer certificado com resultado `Deny` em admin ou user, inclusive uma âncora do sistema; `Unspecified`
    não entra;
  - dedupe por DER.
- Limite: respeita só o "nunca confiar" do **usuário**. A lista de distrust e as restrições da Apple aplicadas pelo
  trustd não aparecem nesta API; no PEM essas âncoras viram confiança plena (B′ resolveria).
- Onde: `<root>/network/upstream-ca.pem`, escrita atômica (temp + rename) no diretório já fechado pelo Seatbelt
  (`SandboxProfile.swift:217-218`), só quando o conteúdo muda (compara bytes). Sem hash nem checagens extras: o
  `mitmdump` lê o arquivo tarde (item 7), e quem pode escrever ali já pode editar o `config.yaml`.
- **Nunca apagar** o arquivo enquanto houver sessão; a escrita acontece antes de montar os args.
- Falhou (erro do framework, zero certificados, disco): sobe sem o pacote (certifi) e escreve uma linha em
  `standardError` com o motivo.

### 2. Subida e args

- `MitmProcess.start(…, upstreamCA: @Sendable () -> UpstreamCA)` guarda a closure e a chama em todo `startOnce`
  (attach e restart). `UpstreamCA = (url: URL?, mode: "system" | "user-config" | "unavailable", certs: Int?)`.
- `MitmProcess.args(…, upstreamCA: URL?)` acrescenta `--set ssl_verify_upstream_trusted_ca=<path>` quando não nulo.
- A closure devolve `user-config` (e não monta o pacote) quando o `<confdir>/config.yaml` define
  `ssl_verify_upstream_trusted_ca`, `ssl_verify_upstream_trusted_confdir` ou `ssl_insecure: true`
  (`ssl_insecure: false` não conta). Leitura tolerante: chave de topo na coluna 0, ignora comentários. Como o
  arquivo vence o `--set` de qualquer jeito, isso só serve ao status e para não montar à toa; YAML não trivial
  (aspas, flow-style, BOM) pode fazer o status dizer `system` quando o `mitmdump` usa a config do usuário: o status
  é estimativa nesse caso.
- `ssl_insecure: true` no `config.yaml`: uma linha em `standardError`, para uma verificação desligada não passar em
  silêncio.
- `NetworkProxy` ganha `var upstreamCA: UpstreamCA { get }` (o `FakeProxy` dos testes também). `network.status`
  mostra `upstreamCA` e `certs` **só com `attached:true`**. O painel decodifica com `Decodable` e ignora o campo;
  daemon antigo com app novo: o campo só não aparece.
- `NetworkService.init(root:…)` (`NetworkService.swift:83-97`, chamado em `CommandRouter.swift:187`) injeta a fonte
  real.

### 3. Segurança

- O `mitmdump` passa a confiar no que o macOS já confia para este usuário (B), e só para verificar o **destino**.
  Não muda o que o emulador confia (a CA do Collie).
- Uma CA com trust settings posta por malware já engana o navegador; não é risco novo. Em B um certificado só
  gravado no keychain não basta (precisa de trust settings, que pedem o diálogo do sistema): por isso A nunca é
  fallback.
- CAs de desenvolvimento com chave privada no disco (Proxyman, mkcert, Caddy) entram, como no Safari. Documentar.
- A verificação continua sempre ligada; nunca `ssl_insecure`.
- Log: só modo, contagem e motivo. Sem PEM, sem nomes de certificado.
- Diferença Apple × Mozilla: algumas raízes do certifi podem não existir no macOS e vice-versa. Aceito.

### 4. Testes (`swift test --filter`, nada de Keychain real nem rede externa)

- `UpstreamTrustTests`: âncora entra; admin `TrustRoot` autoassinado entra; `TrustRoot` não autoassinado não entra;
  `TrustAsRoot` não autoassinado entra; `PolicyString` não entra; política só S/MIME ou Code Signing não entra;
  `Unspecified` não entra; `Deny` sai (inclusive âncora negada no user); certificado nas âncoras e no admin sai uma
  vez só; PEM bem formado; escrita só quando muda; fonte que lança → sem pacote, `unavailable`.
- `NetworkMitmTests`: args com e sem pacote; `config.yaml` com cada chave → `user-config`; `ssl_insecure: false` →
  `system`; chave comentada ou indentada não conta; o `restarted` chama a closure de novo.
- `NetworkServiceTests`: `upstreamCA` no status só com sessão (`FakeProxy`).
- Opcional, `COLLIE_E2E_MITM=1` (harness `realMitm`, `NetworkMitmTests.swift:59-69`, 206-328): servidor HTTPS em
  `127.0.0.1` assinado por uma CA de teste gerada no teste; com o pacote contendo a CA → 200; sem ele → linha
  `error` com "Certificate verify failed"; `config.yaml` com outro `ssl_verify_upstream_trusted_ca` vence o `--set`.
- Só à mão: máquina corporativa (CA de MDM aparece? 200 sem o `config.yaml` manual? nenhum diálogo de keychain?).

## Minhas chamadas (conferir)

- B como padrão, condicionado à Tarefa 1; B′ como plano B.
- Sem interruptor por ora: quem não quer põe a opção no próprio `config.yaml`.
- Pacote em `<root>/network/upstream-ca.pem`, refeito a cada subida, sem vigiar o Keychain.

## Fica para depois

- **Aviso do 502 no painel**: a falha já chega como linha `error` ("Certificate verify failed: …") e o painel já
  mostra a mensagem crua. Opcional e trivial, sem tela nova: um `notice` quando houver essa mensagem e
  `upstreamCA != system`.
- **Interruptor nas Preferências**: não existe página Rede; o lugar natural é Preferências → Android, no modelo de
  `admin.fonts`.
- **Proxy corporativo upstream** (PAC/`scutil --proxy`): o `mitmdump` sai direto e a rede pode bloquear; seria
  `--mode upstream:` lido do sistema. Outro spec.

## Tarefas independentes

1. **Validação na máquina corporativa** (antes de tudo): `dump-trust-settings`, protótipo B e B′; escolhe o critério.
2. `UpstreamTrust`: snapshot injetável, regra B com dedupe, escrita atômica, fonte real.
3. `MitmProcess.start(upstreamCA:)` + args + leitura tolerante do `config.yaml`; `upstreamCA` no `NetworkProxy`, no
   `FakeProxy` e no status.
4. Injetar a fonte real em `NetworkService.init(root:…)`.
5. Teste E2E opcional com `COLLIE_E2E_MITM`.
