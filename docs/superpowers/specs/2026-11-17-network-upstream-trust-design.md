# CAs do macOS para o destino no painel Rede — design

Status: rascunho para aprovação. Nada implementado. Escopo escolhido pelo dono: só o padrão automático.

## Intenção e porquê

Numa máquina gerenciada pela empresa, o painel Rede devolveu 502 em todos os pedidos do emulador, com
"Certificate verify failed: self-signed certificate in certificate chain". A rede inspeciona TLS e reassina os
certificados com uma CA corporativa que está no Keychain; o `mitmdump` confia só no pacote próprio (certifi) e
rejeita o **servidor de destino**. A correção manual (exportar as CAs dos keychains para um `.pem` e apontar
`ssl_verify_upstream_trusted_ca` no `<confdir>/config.yaml`) funcionou. O Collie deve fazer isso sozinho.

## Estado atual (verificado no código)

1. `confdir = <root>/network/mitm` (`NetworkService.swift:85`), 0700, guarda a chave da CA do Collie.
2. `MitmProcess.args` (`MitmProcess.swift:41-43`): `--listen-host 127.0.0.1 -p <porta> --set confdir=… --set
   http2=false -q -s <addon>` e `--set collie_rules=…`. Nenhuma opção de TLS para o destino.
3. `MitmTool.locate`: `COLLIE_MITMDUMP`, `/opt/homebrew/bin`, `/usr/local/bin`. Instalado aqui: mitmproxy 12.3.1.
4. `mitmdump --options`: `ssl_verify_upstream_trusted_ca` (PEM), `ssl_verify_upstream_trusted_confdir`,
   `ssl_insecure: false`. O mitmproxy lê `<confdir>/config.yaml` sozinho; `--set` vence o arquivo.
5. No mitmproxy (`net/tls.py`, `create_proxy_server_context`) o pacote informado **substitui** o certifi, não soma.
   Logo o nosso pacote precisa trazer também as raízes públicas (as do macOS trazem).

## Metas

- Ao subir cada `mitmdump`, o daemon monta um pacote com as CAs em que o **macOS** confia e o passa ao `mitmdump`.
- O `config.yaml` do usuário nunca é sobrescrito nem contrariado (é também a saída para quem não quer o padrão).
- Falha ao montar o pacote nunca impede o Interceptar.

## Anti-metas

- Nunca `ssl_insecure` nem qualquer desligamento da verificação.
- Nunca ler, exportar ou gravar chave privada: só certificados públicos.
- Nunca pedir senha nem senha de keychain; nunca abrir diálogo do sistema.

## Abordagens consideradas

**Como montar o pacote**
- A. `security find-certificate -a -p <3 keychains>` (o comando manual). Medido aqui: 40 ms, 171 certificados,
  260 KB. Despeja **tudo** que está nos keychains, inclusive intermediários e certificados que o macOS não trata como
  raiz (importados sem confiança ou marcados "nunca confiar"): confia em mais do que o macOS confia.
- B. **Security.framework**: `SecTrustCopyAnchorCertificates` (raízes do sistema) + `SecTrustSettingsCopyCertificates`
  nos domínios admin e user, filtrando por `SecTrustSettingsCopyTrustSettings`. Medido aqui (protótipo descartável):
  263 ms com carga do framework, 155 + 4 certificados, 245 KB, sem senha nem diálogo. Dá "o que o macOS trata como
  raiz" e resolve o distrust de graça. **Escolhida.**
- C. A + pós-filtro com `security dump-trust-settings`: dois processos e parse de texto. Descartada.

**Como passar ao `mitmdump`**
- A. **`--set ssl_verify_upstream_trusted_ca=<pacote>`** em `MitmProcess.args`, só se o `config.yaml` do usuário não
  tratar do assunto. **Escolhida.**
- B. Escrever no `config.yaml`: clobra a config do usuário. Descartada.

## Design

### 1. Pacote (`UpstreamTrust`, em `CollieDaemonKit/Network`)

- Fonte injetável: `certificates: @Sendable () throws -> TrustSnapshot`, com as raízes do sistema (`[Data]` DER) e,
  por domínio admin/user, `[(der: Data, settings: [[String: Any]])]`. A real usa o Security.framework; os testes
  passam fixtures.
- Regra (função pura `bundle(_:) -> (pem: String, count: Int, denied: Int)`):
  - entra toda raiz do sistema;
  - entra um certificado admin/user cujas trust settings estão vazias (vazio = "raiz para tudo") ou têm um item com
    resultado `TrustRoot`/`TrustAsRoot` (ausente conta como `TrustRoot`) e sem `kSecTrustSettingsPolicy` ou com a
    política SSL;
  - sai qualquer certificado com resultado `Deny` em admin ou user, **inclusive uma raiz do sistema** marcada "nunca
    confiar" (compara pelo DER); `Unspecified` não entra.
  - Limite conhecido: a lista de revogação de raízes da Apple (fora do Keychain) não é vista; documentar.
- Onde: `<root>/network/upstream-ca.pem`, 0600, escrita atômica e só quando o conteúdo muda (compara bytes).
- Quando: a cada subida de `mitmdump` (attach e `restarted`); é o "regenerar quando mudar", sem hash nem mtime de
  keychain. Custa ~¼ s, menos que o `mitmdump` subir. Roda fora do ator, como as outras chamadas lentas.
- Falhou (erro do framework, zero raízes, disco): segue **sem** o pacote (certifi) e registra uma linha no log do
  daemon com o motivo.

### 2. Args

`MitmProcess.args(…, upstreamCA: URL?)` acrescenta `--set ssl_verify_upstream_trusted_ca=<path>` quando não nulo.
O `NetworkService` passa nil quando `<confdir>/config.yaml` define `ssl_verify_upstream_trusted_ca`,
`ssl_verify_upstream_trusted_confdir` ou `ssl_insecure` (escolha do usuário, inclusive a correção manual de hoje), e
nesse caso nem monta o pacote. Leitura tolerante: varre linhas, casa `^(chave)\s*:` na coluna 0 (chave de topo),
ignora comentários. Arquivo ausente ou ilegível = não define. Sem biblioteca YAML.

`network.status` ganha `upstreamCA: "system" | "user-config" | "unavailable"` (e `certs` no primeiro caso), para
diagnóstico pelo CLI. Sem UI.

### 3. Segurança

- O `mitmdump` passa a confiar no mesmo conjunto que Safari e o resto do macOS já confiam para este usuário, e só para
  verificar o **destino**. Não muda o que o emulador confia (a CA do Collie).
- Uma CA posta no Keychain por malware já engana o navegador do usuário; não é risco novo. Distrust explícito é
  respeitado.
- A verificação continua sempre ligada; nunca `ssl_insecure`.
- Log: só modo, contagem e motivo do erro. Sem PEM, sem nomes de certificado.
- Diferença Apple × Mozilla: algumas raízes do certifi podem não existir no macOS e vice-versa. Aceito: o critério é
  "o que o macOS confia".

### 4. Testes (`swift test --filter`, nada de Keychain real nem rede)

- `UpstreamTrustTests`: fixture de 2–3 DER pequenos; raiz do sistema entra; admin com `TrustRoot` entra; `Deny` sai
  (inclusive raiz do sistema negada no user); política só S/MIME não entra; `Unspecified` não entra; PEM bem formado;
  escrita só quando muda; fonte que lança → sem pacote, `unavailable`.
- `NetworkMitmTests`: args com e sem pacote; `config.yaml` definindo cada uma das três chaves → sem `--set`; chave
  comentada ou indentada não conta.
- Só à mão: máquina com rede corporativa, sem o `config.yaml` manual → 200; nenhum diálogo de keychain aparece.

## Minhas chamadas (conferir)

- Security.framework em vez de `security find-certificate` (mais estrito que a correção manual).
- Sem interruptor por ora: quem não quer põe a opção no próprio `config.yaml`.
- Pacote em `<root>/network/upstream-ca.pem`, regenerado a cada subida, sem vigiar o Keychain.

## Fica para depois

- **Aviso do 502 no painel**: o addon já manda a falha como linha `error` (`flow.error.msg`, "Certificate verify
  failed: …") e o painel já mostra a mensagem crua no fluxo. Opcional e trivial, sem tela nova: um `notice` do
  painel quando houver essa mensagem e `upstreamCA != system`. Formato exato do 502 a confirmar à mão.
- **Interruptor nas Preferências**: não existe página Rede; o lugar natural é Preferências → Android, no modelo de
  `admin.fonts`.
- **Proxy corporativo upstream** (PAC/`scutil --proxy`): o `mitmdump` sai direto e a rede pode bloquear; seria
  `--mode upstream:` lido do sistema. Outro spec.

## Tarefas independentes

1. `UpstreamTrust`: snapshot injetável, regra pura, escrita atômica, fonte real do Security.framework.
2. `MitmProcess.args(upstreamCA:)` + leitura tolerante do `config.yaml`.
3. `NetworkService`: monta/decide na subida, `upstreamCA` no `network.status`.
4. Verificação à mão na máquina com rede corporativa.
