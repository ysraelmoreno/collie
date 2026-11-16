# Painel Rede: responder no lugar do servidor (map local)

Regras de map local trocam a resposta de uma requisição do emulador capturado por uma resposta fabricada (status,
cabeçalhos, corpo), por uma queda de conexão, ou atrasam a resposta. O servidor não é chamado. Spec:
`docs/superpowers/specs/2026-11-15-network-mapping-design.md`.

## Como funciona

- As regras são globais ao Mac (não por cercado) e ficam em `<root>/network/rules.json`. A cada início do daemon, todas
  voltam **desligadas**; o painel mostra "N regras salvas estão desligadas" até você ligar o que precisa.
- O daemon grava as regras ligadas, em ordem, em `<root>/run/network/rules.json` (troca atômica, modo 0600). Todo
  `mitmdump` lê esse arquivo e o relê quando ele muda, sem reiniciar. Se o arquivo vier inválido, as regras anteriores
  continuam valendo.
- Vence a **primeira regra ligada** que casa. Método sem diferença de caixa; host e caminho são globs (`fnmatch`:
  `*.example.com`, `/pdp/v2/products/*`); o caminho não inclui a query; `--query k=v` exige o par, em qualquer ordem.
- Todo fluxo atendido por regra sai marcado: `mappedBy` em `network.get`, "mapeado · <regra>" na linha e no detalhe.
- Regra de **agente** (`rule-add`, `rule-enable` vindos de um terminal) nasce desligada e só liga com **Permitir** no
  cartão "Responder no lugar do servidor?". Negar ou 120 s sem resposta: fica desligada e o comando falha. Regras do
  app e da CLI do usuário valem na hora. `rule-disable`, `rule-remove` e `rule-clear` nunca pedem cartão.
- `--body-file` é lido pelo daemon na criação (o addon nunca lê caminho). Terminal: só dentro do próprio projeto.
  App/CLI do usuário: qualquer caminho. Teto de 5 MiB. `content-encoding` e `content-length` são recusados nos
  cabeçalhos (o corpo vai sem compressão). Sem `Content-Type`, ele é deduzido do corpo (JSON, texto ou binário).

## Exemplos (acme-app-android)

```sh
collie network attach                       # o emulador já capturado pelo painel Rede

# PDP com desconto, a partir do JSON do repositório
collie network rule-add --name "PDP com desconto" --host api.example.com \
  --path '/pdp/v2/products/*' --body-file json/discount_pdp.json

# Partindo de um fluxo capturado: copia status, cabeçalhos e corpo (já descomprimido); as flags sobrescrevem
collie network list --host api.example.com
collie network rule-add --from <id do fluxo> --status 500 --body '{"error":"indisponível"}'

# Checkout com erro 500
collie network rule-add --name "Checkout com erro" --method POST --host api.example.com \
  --path '/checkout/*' --status 500 --body '{"error":"boom"}'

# Timeout: espera 8 s e corta a conexão
collie network rule-add --name "Home lenta" --host api.example.com --path /v1/home --drop --delay 8000

collie network rule-list                    # [{id,name,enabled,match,action,status,bodySize,delayMs}]
collie network rule-disable <id>
collie network rule-enable <id>
collie network rule-remove <id>
collie network rule-clear
```

No painel: aba **Regras** (ligar/desligar, remover), botão **Mapear** no detalhe de um fluxo (formulário preenchido
com a resposta capturada; "Escolher arquivo…" para usar um JSON).

## Verificação (2026-11-15)

Feito:
- Testes do addon com o `mitmdump` real 12.3.1 (`COLLIE_E2E_MITM=1 swift test --filter NetworkMitmTests`): resposta
  local sem tocar o servidor, queda, atraso, primeira regra ligada vence, arquivo corrompido ou de versão desconhecida
  mantém as regras, releitura por mudança do arquivo, método e query, fluxo sem regra sem `mappedBy`.
- Daemon isolado (raiz temporária) + `collie network rule-*` pela CLI + um `mitmdump` real com o addon do Collie lendo
  o arquivo de regras desse daemon + servidor HTTP local + `curl --proxy`:
  - `rule-add --host 127.0.0.1 --path '/pdp*' --status 200 --body-file discount_pdp.json`: o `curl` recebeu o JSON
    mapeado e o servidor não foi acessado;
  - `rule-disable`: o `curl` voltou ao servidor;
  - `--status 500 --body …`: 500 com o corpo;
  - `--drop --delay 1500`: o `curl` ficou sem resposta após 1,5 s; a linha `error` do addon trouxe `mappedBy`;
  - reiniciar o daemon: as três regras voltaram desligadas e o arquivo do addon ficou vazio.
- Cartão de agente, negação e prazo: `NetworkRuleApprovalTests` (daemon de teste).

Sem prova ainda (passo do dono, depois de instalar o bundle):
- A sessão do painel com um emulador de verdade (`network.attach` sobe o `mitmdump` com `collie_rules`); no E2E acima o
  `mitmdump` foi iniciado à mão com o mesmo addon e o mesmo arquivo, porque sem emulador não há sessão.
- `--from` com um fluxo real do app; o app `acme-app-android` mostrando a PDP mapeada.
- O cartão e o painel vistos no app instalado (só houve snapshot do painel nos testes).
