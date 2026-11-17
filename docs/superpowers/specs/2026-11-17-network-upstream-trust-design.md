# CAs do macOS para o destino no painel Rede — design

Status: rascunho para aprovação. Nada implementado.

## Intenção e porquê

Numa máquina gerenciada pela empresa, o painel Rede devolveu 502 em todos os pedidos do emulador, com
"Certificate verify failed: self-signed certificate in certificate chain". A rede inspeciona TLS e reassina os
certificados com uma CA corporativa que está no Keychain; o `mitmdump` confia só no pacote próprio (certifi) e
rejeita o **servidor de destino**. A correção manual (exportar as CAs dos keychains para um `.pem` e apontar
`ssl_verify_upstream_trusted_ca` no `<confdir>/config.yaml`) funcionou. O dono quer que o Collie faça isso sozinho e
avise com clareza.

## Estado atual (verificado no código)

1. `confdir = <root>/network/mitm` (`NetworkService.swift:85`), 0700, guarda a chave da CA do Collie.
2. `MitmProcess.args` (`MitmProcess.swift:41-43`): `--listen-host 127.0.0.1 -p <porta> --set confdir=… --set
   http2=false -q -s <addon>` e `--set collie_rules=…`. Nenhuma opção de TLS para o destino.
3. `MitmTool.locate`: `COLLIE_MITMDUMP`, `/opt/homebrew/bin`, `/usr/local/bin`. Instalado aqui: mitmproxy 12.3.1.
4. O addon (`Sources/CollieNetwork/AddonScript.swift`) escreve `request`, `response`, `error` (com
   `flow.error.msg`) e `tunneled`. Falha de conexão com o destino chega como linha `error` e o fluxo fica
   `FlowState.failed(msg)`; o painel já mostra a mensagem crua (`NetworkPanelView.swift:211`).
5. `mitmdump --options`: `ssl_verify_upstream_trusted_ca` (PEM), `ssl_verify_upstream_trusted_confdir`,
   `ssl_insecure: false`. O mitmproxy lê `<confdir>/config.yaml` sozinho; `--set` vence o arquivo.
6. No mitmproxy (`net/tls.py`, `create_proxy_server_context`) o pacote informado **substitui** o certifi, não soma.
   Logo o nosso pacote precisa trazer também as raízes públicas (as do macOS trazem).
7. Não há página de Preferências "Rede"; a interceptação é do emulador Android (`AndroidPreferences.swift`). A seção
   "Rede" de `CelularPreferences` é outra coisa (escuta do iPhone).

## Metas

- Ao subir cada `mitmdump`, o daemon monta um pacote com as CAs em que o **macOS** confia e o passa ao `mitmdump`,
  ligado por padrão.
- O `config.yaml` do usuário nunca é sobrescrito nem contrariado.
- Falha de verificação do destino vira um aviso claro em pt-BR no painel, com o que o Collie fez e como desligar.

## Não metas

- Proxy corporativo upstream (PAC, `scutil --proxy`): ver "Fica para depois".
- Recarregar o pacote com o `mitmdump` rodando: vale no próximo Interceptar.
- Certificate pinning do app (continua invisível, como hoje).

## Anti-metas

- Nunca `ssl_insecure` nem qualquer desligamento da verificação.
- Nunca ler, exportar ou gravar chave privada: só certificados públicos.
- Nunca pedir senha nem senha de keychain; nunca abrir diálogo do sistema.
- Uma falha ao montar o pacote nunca impede o Interceptar.

## Abordagens consideradas

**Como montar o pacote**
- A. `security find-certificate -a -p <3 keychains>` (o comando manual). Medido aqui: 40 ms, 171 certificados,
  260 KB. Problema: despeja **tudo** que está nos keychains, inclusive intermediários e certificados que o macOS não
  trata como raiz (importados sem confiança, ou marcados "nunca confiar"). Confiar neles é mais do que o macOS confia.
- B. **Security.framework**: `SecTrustCopyAnchorCertificates` (raízes do sistema) + `SecTrustSettingsCopyCertificates`
  nos domínios admin e user, filtrando por `SecTrustSettingsCopyTrustSettings`. Medido aqui (protótipo descartável):
  263 ms com carga do framework, 155 + 4 certificados, 245 KB, sem senha nem diálogo. Dá exatamente "o que o macOS
  trata como raiz" e resolve o distrust de graça. **Escolhida.**
- C. Rodar A e pós-filtrar com `security dump-trust-settings`: dois processos e parse de texto. Descartada.

**Como passar ao `mitmdump`**
- A. **`--set ssl_verify_upstream_trusted_ca=<pacote>`** em `MitmProcess.args`, só se o interruptor estiver ligado e o
  `config.yaml` do usuário não tratar do assunto. **Escolhida.**
- B. Escrever no `config.yaml`: clobra a config do usuário. Descartada.

## Design

### 1. Pacote (`UpstreamTrust`, em `CollieDaemonKit/Network`)

- Fonte injetável: `certificates: @Sendable () throws -> TrustSnapshot`, onde `TrustSnapshot` traz as raízes do
  sistema (`[Data]` DER) e, por domínio admin/user, `[(der: Data, settings: [[String: Any]])]`. A real usa o
  Security.framework; os testes passam fixtures.
- Regra (função pura `bundle(_:) -> (pem: String, count: Int, denied: Int)`):
  - entra toda raiz do sistema;
  - entra um certificado admin/user cujas trust settings estão vazias (vazio = "raiz para tudo") ou têm um item com
    resultado `TrustRoot`/`TrustAsRoot` (ausente conta como `TrustRoot`) e sem `kSecTrustSettingsPolicy` ou com a
    política SSL;
  - sai qualquer certificado com resultado `Deny` em admin ou user, **inclusive uma raiz do sistema** que o usuário
    marcou "nunca confiar" (compara pelo DER); `Unspecified` não entra.
  - Limite conhecido: a lista de revogação de raízes da Apple (fora do Keychain) não é vista; documentar.
- Onde: `<root>/network/upstream-ca.pem`, 0600 (nada secreto, mas não há por que expor), escrita atômica e só quando
  o conteúdo muda (compara bytes).
- Quando: a cada subida de `mitmdump` (attach e `restarted`). Custa ~¼ s, menos que o próprio `mitmdump` subir; sem
  hash nem mtime de keychain (YAGNI). Roda fora do ator, como as outras chamadas lentas.
- Falhou (erro do framework, zero raízes, disco): segue **sem** o pacote (certifi), status `unavailable` com o motivo,
  uma linha no log do daemon.

### 2. Args

`MitmProcess.args(…, upstreamCA: URL?)` acrescenta `--set ssl_verify_upstream_trusted_ca=<path>` quando não nulo.
O `NetworkService` decide o valor:

- interruptor desligado → nil, modo `off`;
- `<confdir>/config.yaml` define `ssl_verify_upstream_trusted_ca`, `ssl_verify_upstream_trusted_confdir` ou
  `ssl_insecure` → nil, modo `user-config` (a escolha é do usuário, inclusive a correção manual de hoje);
- senão → o pacote, modo `system` com `certs: N`.

Leitura tolerante: varre linhas, casa `^(chave)\s*:` na coluna 0 (chave de topo), ignora `#`. Arquivo ausente ou
ilegível = não define. Sem biblioteca YAML.

### 3. Detecção e aviso

- Casa quando uma linha `error` tem mensagem com `certificate verify failed` (sem diferenciar maiúsculas), ou uma
  `response` 502 cujo corpo (primeiros 4 KiB, decodificado) contém o mesmo texto. Os dois porque o formato exato do
  502 não foi confirmado nesta máquina (o bundle do mitmproxy é compilado; o relato do dono mostra o corpo com a
  mensagem pura).
- Por sessão: `upstreamTrust: {mode, certs?, reason?, failures, lastHost}` no `network.status`. Na primeira falha da
  sessão, um evento `network.upstream-tls` (`serial`, `host`, `mode`) para o painel atualizar sem esperar o poll.
- Aviso no painel (`notice`, tom de atenção), por modo:
  - `off`/`unavailable`: "O servidor de destino apresentou um certificado em que o mitmproxy não confia. É comum em
    rede de empresa com inspeção de TLS. O Collie pode confiar nas mesmas CAs que o macOS confia: ligue em
    Preferências → Android → Interceptação e clique em Parar e Interceptar de novo." (`unavailable` acrescenta o
    motivo.)
  - `system`: "O destino apresentou um certificado em que nem o macOS confia (N CAs do sistema em uso). Se a rede da
    empresa inspeciona TLS, a CA dela precisa estar no Keychain."
  - `user-config`: "… seu config.yaml do mitmproxy define a verificação do destino; o Collie não mexe nele."
- Na barra, ao lado do status: "CAs do macOS (N)" no modo `system`.

### 4. Segurança

- Aceitável por padrão: o `mitmdump` passa a confiar no mesmo conjunto que Safari e o resto do macOS já confiam para
  este usuário, e só para verificar o **destino**. Não muda o que o emulador confia (a CA do Collie).
- Uma CA posta no Keychain por malware já engana o navegador do usuário; não é risco novo. Distrust explícito é
  respeitado (abordagem B).
- A verificação continua sempre ligada; nunca `ssl_insecure`.
- Log: só modo, contagem e motivo do erro. Sem PEM, sem nomes de certificado, sem corpo de resposta.
- Quem não quer: interruptor desligado = comportamento de hoje (certifi).
- Diferença Apple × Mozilla: algumas raízes do certifi podem não existir no macOS e vice-versa. Aceito: o critério é
  "o que o macOS confia".

### 5. UX

- Preferências → Android, seção "Interceptação": `Toggle("Confiar nas CAs do macOS para verificar os servidores")`,
  ligado por padrão, nota: "Necessário em redes que inspecionam TLS. A verificação nunca é desligada. Vale no próximo
  Interceptar." Abaixo, o estado da última subida: "Usando CAs do sistema (159 certificados)", "Desligado", "Seu
  config.yaml decide", ou o motivo de `unavailable`.
- Guardado no daemon como os outros interruptores de admin (`admin.fonts` como modelo), comando
  `admin.network-trust on|off`.

### 6. Testes (`swift test --filter`, nada de Keychain real nem rede)

- `UpstreamTrustTests`: fixture de 2–3 DER pequenos; raiz do sistema entra; admin com `TrustRoot` entra; `Deny` sai
  (inclusive raiz do sistema negada no user); política só S/MIME não entra; `Unspecified` não entra; PEM bem formado
  (64 colunas, BEGIN/END); escrita só quando muda; fonte que lança → `unavailable`.
- `NetworkMitmTests`: args com pacote, sem pacote (desligado), e com `config.yaml` definindo cada uma das três
  chaves (inclusive comentada e indentada, que não contam).
- `NetworkServiceTests`: linha `error` "Certificate verify failed: …" conta falha, preenche `lastHost` e emite o evento
  uma vez; 502 com o texto no corpo também; 502 sem o texto não.
- `NetworkPanelTests`: texto do aviso por modo.
- Só à mão: máquina com rede corporativa (sem config.yaml manual, ligado → 200; desligado → aviso); confirmar o
  formato real do 502/`error` no `mitmdump` 12.3.1 e que nenhum diálogo de keychain aparece.

## Minhas chamadas (conferir)

- Security.framework em vez de `security find-certificate` (mais estrito que a correção manual).
- Interruptor nas Preferências → Android, não no painel; o painel só avisa e aponta.
- Ligado por padrão, inclusive para quem já usa o Collie hoje.
- `config.yaml` com qualquer das três chaves faz o Collie sair do caminho (o dono pode apagar o seu manual depois).
- Pacote em `<root>/network/upstream-ca.pem`, regenerado a cada subida, sem vigiar o Keychain.
- Textos do aviso e do interruptor.

## Fica para depois

- Proxy corporativo upstream (PAC/`scutil --proxy`): o `mitmdump` sairia direto e a rede pode bloquear; seria
  `--mode upstream:` lido das configurações do sistema. Outro spec.
- Recarregar o pacote quando o Keychain muda com a sessão aberta.

## Tarefas independentes

1. `UpstreamTrust`: snapshot injetável, regra pura, escrita atômica, fonte real do Security.framework.
2. `MitmProcess.args(upstreamCA:)` + leitura tolerante do `config.yaml`.
3. `NetworkService`: monta/decide na subida, guarda o modo, `upstreamTrust` no status.
4. Detecção nas linhas `error`/`response` + contador + evento `network.upstream-tls`.
5. `admin.network-trust` (persistência, padrão ligado).
6. Painel: aviso por modo e "CAs do macOS (N)" na barra.
7. Preferências → Android: seção "Interceptação" com interruptor e estado.
8. Verificação à mão na máquina com rede corporativa.
