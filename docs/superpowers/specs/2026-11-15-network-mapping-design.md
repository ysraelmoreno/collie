# Substituir respostas no painel Rede (map local) — design

Status: rascunho para aprovação. Nada implementado.

## Intenção e porquê

O painel Rede captura o tráfego HTTP(S) do emulador Android (um `mitmdump` por serial, addon que escreve uma linha
JSON por fluxo). O dono quer **trocar a resposta** de uma requisição (estilo Map Local / Map Remote do Charles):
testar no app um erro 500, uma lista vazia, uma resposta lenta ou um JSON específico (os `*_pdp.json` do
`acme-app-android`) sem mexer no backend. Também serve ao agente: "responda o PDP com `discount_pdp.json` e me diga
se a tela aguenta".

## Estado atual (verificado no código)

1. O addon (`Sources/CollieNetwork/AddonScript.swift`) só **escreve**: `request`, `response`, `error`, `websocket_start`
   viram linhas JSON em stdout. Não lê nada do daemon.
2. Cada serial tem seu `mitmdump` (`NetworkService.Session`, `MitmProcess`); o addon é gravado em
   `<runDir>/network/addon-<porta>.py` e o processo sobe com `-s <addon>` e opções `--set`.
3. Os comandos do painel (`network.attach|detach|status|list|get|curl|clear`) são do plug-in embutido
   (`Sources/ColliePlugins/NetworkPanel.swift`), rodados por `CommandRouter.networkCommand`. A coleira é a permissão:
   o terminal precisa alcançar um painel de rede; o app (admin) não precisa.
4. `Flow`/`FlowSummary`/`FlowStore` (`CollieNetwork`) guardam o que o addon mandou. Não existe a noção de "fluxo
   mapeado".

## Metas

- Regras de **map local**: uma requisição que casa com a regra recebe uma resposta fabricada (status, cabeçalhos,
  corpo) sem chegar ao servidor.
- **Atraso** (`delayMs`) e **queda** (`drop`: a conexão é cortada) como ações, para testar lentidão e timeout.
- Criar a regra **a partir de um fluxo capturado** (`--from <id>`), com edição por flags.
- Todo fluxo atendido por regra aparece **marcado** no painel e no `network.get` (`mappedBy`), para ninguém depurar um
  mock achando que é o servidor real.
- Regras criadas por **agente** só valem depois do seu OK em um cartão; as do app/CLI do usuário valem na hora.
- Regras salvas, mas **desligadas** a cada início do daemon.

## Não metas

- **Map remote** (reescrever host/caminho) fica para depois (fatia 3 do plano geral); o desenho deixa o formato aberto.
- Editar parte do corpo (trocar um campo do JSON) e `times` (valer só N vezes): fora da v1.
- Tráfego que não é do emulador anexado; tráfego do Mac.
- Driblar certificate pinning (hoje o app pinado já é invisível).

## Anti-metas

- Nenhuma regra de agente vale sem o cartão.
- O addon nunca lê arquivo do disco por caminho de regra: o daemon resolve `--body-file` na criação e grava os bytes
  na regra. Assim o addon não vira um jeito de ler arquivos fora do cercado.
- Uma regra mal formada nunca derruba o `mitmdump` nem apaga as regras que funcionavam.

## Abordagens consideradas

**Canal daemon → addon**
- A. **Arquivo de regras** que o daemon grava (escrita atômica) e o addon relê quando o `mtime` muda, checando a cada
  requisição. Sem protocolo novo, sem reiniciar o `mitmdump`. Escolhida.
- B. `--set` de opções do mitmproxy: não atualiza em tempo real.
- C. Stdin do `mitmdump`: ele não lê comandos nesse modo.

**Onde casar**
- A. **No addon (Python)**, com `fnmatch` para host e caminho. Uma só implementação: o daemon só valida o formato.
  Escolhida.
- B. No daemon: obrigaria a ida e volta por requisição.

## Design

### 1. Modelo da regra (`CollieNetwork/MapRule.swift`)

```
MapRule { id: String            // curto, gerado
          name: String?
          enabled: Bool
          match: Match          // method?: String, host?: glob, path?: glob (sem query), query?: [String:String]
          action: Action }      // local | drop, mais delayMs
Action.local: status 100...599, headers [Header], bodyB64: String? (≤ 5 MiB decodificado)
Action.drop: corta a conexão
delayMs: 0...60000 (vale para local e drop; com drop vira "timeout")
```

- A primeira regra **ligada** que casa, na ordem da lista, vence. `match` vazio = casa tudo (a UI/CLI pede
  confirmação extra ao criar assim).
- Validação: no máximo 100 regras; arquivo inteiro ≤ 20 MiB; cabeçalho `content-encoding` e `content-length` não são
  aceitos (o corpo vai como está, sem compressão; o mitmproxy calcula o tamanho); glob de 1 a 200 caracteres.
- `Content-Type` padrão: o informado; senão `application/json` se o corpo é JSON válido, `text/plain` se é texto,
  `application/octet-stream` nos demais.

### 2. Arquivo de regras e o addon

- `<runDir>/network/rules.json` (um para o daemon: todo `mitmdump` lê o mesmo), escrito por `.atomic`, modo 0600.
  Conteúdo: `{"v":1,"rules":[ …só as regras ligadas, em ordem… ]}`.
- O addon ganha a opção `collie_rules` (caminho). A cada requisição ele faz `os.stat`; se o `mtime` mudou, relê. JSON
  inválido ou versão desconhecida: **mantém as regras anteriores**.
- No hook `request` (agora `async`), antes de emitir a linha do fluxo:
  - acha a regra; sem regra, segue o fluxo normal (a linha não muda);
  - `delayMs` → `await asyncio.sleep`;
  - `drop` → `flow.kill()`; `local` → `flow.response = http.Response.make(status, corpo, cabeçalhos)`.
  - a linha `request` e, depois, a `response` levam `"mappedBy": "<id da regra>"`.
- O hook `response` ainda dispara para respostas fabricadas, e a linha `response` leva o mesmo `mappedBy`.

### 3. Fluxo e painel

- `FlowEvent.Request/Response` ganham `mappedBy: String?`; `Flow.mappedBy`; `FlowSummary.mapped: Bool`; `network.get`
  devolve `mappedBy`. Sem o campo, nada muda (compatível com o addon antigo).
- Painel: o fluxo mapeado ganha uma marca ("mapeado") na linha e no detalhe, com o nome da regra.
- Painel: lista de regras (ligar/desligar, remover, ordem) e o botão "Mapear esta resposta" no detalhe do fluxo, que
  abre o formulário já preenchido com a resposta capturada (status, cabeçalhos úteis, corpo editável).

### 4. Comandos (plug-in `network`, nomes com hífen)

`rule-add`, `rule-list`, `rule-remove <id>`, `rule-enable <id>`, `rule-disable <id>`, `rule-clear`.

`rule-add` aceita: `--name`, `--method`, `--host`, `--path`, `--query k=v` (repetível), `--status`, `--header
"Nome: valor"` (repetível), `--body "<texto>"` ou `--body-file <caminho>`, `--delay <ms>`, `--drop`, `--from <id do
fluxo>` (copia status, cabeçalhos e corpo da resposta capturada; as flags sobrescrevem), `--disabled`.
`--body-file`: o daemon lê na criação, só dentro do cercado do chamador (ou onde o sandbox deixaria o chamador
ler), ≤ 5 MiB; o app/admin não tem essa restrição de cercado, só o teto de tamanho.

### 5. Aprovação das regras de agente

- Chamador admin (app) ou o usuário na CLI: vale na hora.
- Chamador terminal-agente: `rule-add` e `rule-enable` levantam um cartão
  "<terminal> quer responder `<método> <host><caminho>` com `<status>` (corpo de N KB, atraso X ms)" — **Permitir /
  Negar**; sem resposta no prazo é Negar. A regra nasce **desligada** e é ligada só com o Permitir.
  Reaproveita o mecanismo do cartão `confirm` dos apps (`PaddockApps.confirmAppCall`); se não der para reutilizar sem
  refatorar, o executor para e pergunta.
- `rule-remove` e `rule-disable` por agente valem na hora (reduzem o efeito).

### 6. Persistência

`<root>/network/rules.json` do usuário (separado do arquivo que o addon lê) guarda todas as regras. A cada início do
daemon todas voltam **desligadas**; o painel mostra "N regras desligadas" até o usuário ligar.

## Decisões do dono

- v1 só map local, mais atraso e queda (sem map remote).
- CLI/agente primeiro, UI do painel na sequência.
- Regras de agente com cartão.
- Regras salvas e desligadas ao reabrir.

## Minhas chamadas (conferir)

- **Regras globais ao Mac, não por cercado.** O dono pediu "salvas por cercado", mas o painel Rede não pertence a um
  cercado e há um `mitmdump` por serial; ligar regra a cercado exigiria resolver "de qual cercado é este fluxo". Uma
  lista global, desligada ao reabrir, cobre o motivo (não esquecer um mock ligado).
- Arquivo de regras **único**, lido por todos os `mitmdump`.
- O corpo do arquivo é embutido na regra (base64), não referenciado.
- `times` e edição parcial ficam de fora.
- `content-encoding` recusado em vez de tentar recomprimir.

## Fica para quem construir

- Texto exato dos cartões e dos erros.
- Como o painel mostra a lista de regras (aba, lateral, folha), seguindo o desenho existente do painel.
- Se a regra "casa tudo" precisa de cartão também para o usuário (recomendado só um aviso no formulário).

## Verificação

Teste do addon com o `mitmdump` real do mesmo jeito que `NetworkMitmTests`; E2E em daemon isolado com um servidor
local e `curl` passando pelo proxy. O teste ao vivo com emulador e o app de verdade é passo do dono depois de instalar.
