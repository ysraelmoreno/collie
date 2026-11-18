# Adotar ferramentas existentes e Generative UI — design

Status: rascunho para aprovação. Nada implementado. Duas fases; a fase 1 é o que o dono quer primeiro.

## Intenção e porquê

O dono trabalha num repo (`acme-app-android`) que já tem uma ferramenta local de debug de eventos de analytics
(`tools/page-load-metrics-live/`, Go, servidor web). Quer **anexá-la ao Collie de forma simples** para o agente
usá-la com facilidade: o agente lê os eventos, limpa o log, e o dono vê a UI no canvas.

Hoje isso exige escrever à mão um manifesto `apiVersion 2` (spec `2026-11-08-paddock-apps-design.md`). O
`collie app new` cria um esqueleto vazio, não adota uma ferramenta que já existe.

A segunda ideia do dono, **Generative UI**: o agente cria uma UI no meio da resposta, ao lado dela; a UI vira
ferramenta de volta para o agente e se atualiza sozinha com o que o agente produz. Abordagem escolhida pelo dono:
**C** (spec declarativa para o comum, HTML livre como escape).

## Estado atual (verificado)

- Apps do cercado, fatias 1–5 existem: manifesto v2, aprovação com SHA fixado, comandos `runs: "http"`, SSE
  (`eventStream`), `collie.context`/`snapshot`, `app new`, supervisão do serviço (`AppServices.swift`,
  `PaddockApps.swift`, `AppCard.swift`).
- Eventos SSE: evento acima de **64 KiB é descartado**; sem `Last-Event-ID`; conexão parada 1 h é refeita
  (memória "Apps do cercado: eventos e limites da fatia 2").
- Painéis têm `PanelPlacement`: `canvas`, `dock.left|right|bottom`, `headless`.
- A ferramenta de analytics (lida em `tools/page-load-metrics-live/PROTOCOL.md` e `run.sh`):
  - sobe com `./run.sh` (precisa de Go), porta 8767, host padrão `0.0.0.0`, health `GET /api/health`;
  - UI em `GET /`; SSE em `GET /api/stream` com `event: document` e o **snapshot JSON completo** a cada ingest;
  - `GET /api/document` (inclui `analyticsEvents`), `POST /api/clear/analytics`, `POST /api/clear`,
    `POST /api/clear/system`, `POST /api/clear/leaks`, `POST /api/host/perfetto/capture`, `/api/dev/*`;
  - o app Android envia `POST /api/ingest/analytics/event`;
  - efeito colateral: se há emulador conectado, `run.sh` roda `adb reverse tcp:8767 tcp:8767`.
- Não confirmado: que os PRs de exemplo (ids omitidos) do repositório do dono são os commits `[PROJ-123]` lidos no clone
  (`3196ce5717`, `ab9ab6810c`, `9ad694259f`). O mapeamento foi por conteúdo, não por ID.

## Metas

### Fase 1 — `collie app adopt`

- Um comando liga uma ferramenta local existente ao cercado, sem o dono escrever manifesto:
  `collie app adopt <id> --url http://127.0.0.1:8767 --start "./run.sh" --cwd tools/page-load-metrics-live`.
- Descoberta dos comandos a partir de, nesta ordem: arquivo `collie.json` na pasta da ferramenta; OpenAPI/Swagger
  servido (`/openapi.json`, `/swagger.json`); senão um manifesto mínimo (só painel + `GET` de leitura que o dono
  indicar com `--cmd nome=GET:/caminho`).
- O resultado é um `collie-plugin.json` v2 comum em `.collie/apps/<id>/`, com o cartão de aprovação de sempre.
  Nada de modelo novo de app.
- Funciona igual em qualquer worktree do repo: a pasta `.collie/apps/<id>/` anda com o repo (decisão do dono a
  confirmar, ver "Minhas chamadas").
- Primeiro caso real: a ferramenta de analytics acima, com manifesto de exemplo (abaixo).

### Fase 2 — Generative UI (C)

- `collie ui show` abre um painel efêmero ao lado do terminal que o criou, sem manifesto e sem cartão de
  aprovação, a partir de (a) uma **spec declarativa** (tabela, lista, gráfico, formulário, botões) desenhada
  nativamente, ou (b) **HTML livre** num painel isolado.
- Agente → UI: `collie ui update <id> --data …` empurra dados; a UI se redesenha.
- UI → agente: ações da UI chegam ao agente como aviso (mesmo canal da fatia 2: dado do app, nunca instrução);
  uma ação pode ser nomeada em tempo de execução, sem manifesto.
- Posição: `nearestFreeFrame` perto do criador (já existe para terminais e Prévias).

## Não metas

- Fase 1 não reescreve nem modifica a ferramenta adotada; só a envolve.
- Fase 1 não infere comandos "adivinhando" rotas por varredura de código-fonte.
- Fase 2 não embute janelas nativas de outros processos (impossível no macOS).
- Nenhuma fase faz push, instala ou reinicia o app por conta própria.

## Anti-metas

- O agente nunca aprova um app. A aprovação é do usuário (decisão 1 da spec de plug-ins).
- Nada de rede além do `service.base` loopback. O serviço pode escutar em `0.0.0.0` (a ferramenta de analytics
  escuta), mas o Collie só fala com `127.0.0.1`.
- Uma UI efêmera sem aprovação (fase 2) **nunca** toca arquivo, rede ou comando do sistema; só a ponte
  `window.collie`. Qualquer ação que saia disso exige `confirm` e cartão, igual aos Apps.
- Dados que vêm da ferramenta (eventos, logs) ficam rotulados como dado do app e nunca viram instrução.

## Abordagens consideradas

**Fase 1**
- A. **`app adopt` com descoberta (escolhida).** Gera um manifesto v2 comum; reaproveita aprovação, pin, SSE,
  supervisão, `confirm`. Custo: precisa de descoberta de comandos e de um passo para o SSE grande.
- B. Pedir ao agente que escreva o manifesto (`app new` + prompt). Zero código, mas depende do agente acertar
  rotas e a UX "simples" some.
- C. Um modo "proxy genérico": painel que só embute a URL e o agente usa `curl`. Rápido, mas sem tools nem
  eventos tipados; não resolve "usar com facilidade".

**Fase 2**
- A. HTML livre num painel isolado. Menor esforço, flexível, visual inconsistente.
- B. Spec declarativa renderizada nativamente. Tema e acessibilidade consistentes, seguro, limitado ao catálogo.
- C. As duas (**escolhida pelo dono**): spec para o comum, HTML livre como escape.

## Design — fase 1

### Comando

```
collie app adopt <id> --url <base-loopback> [--start "<cmd>"] [--cwd <pasta>] [--health /api/health]
                      [--ui /] [--events /api/stream] [--cmd nome=METODO:/caminho ...] [--name <nome>]
```

- Só `127.0.0.1`, `::1` ou `localhost` em `--url`. Outro host: recusa.
- `--cwd` relativo ao repo/cercado; não pode sair dele.
- Roda no cercado do chamador. Escreve só em `.collie/apps/<id>/collie-plugin.json` (e `collie.json` se pedido).
- Depois de escrever, levanta o cartão de aprovação e termina. `collie app attach <id>` abre o painel.
- Idempotente: repetir com os mesmos parâmetros não muda o arquivo; com parâmetros diferentes mostra o diff e
  pede confirmação do chamador antes de sobrescrever (o pin muda, então o cartão pergunta de novo).

### Descoberta de comandos

1. `collie.json` na pasta da ferramenta, formato = o bloco `commands` do manifesto v2. Fonte da verdade quando
   existe; permite ao dono do repo fixar o contrato.
2. OpenAPI/Swagger em `/openapi.json` ou `/swagger.json` do serviço (só depois de subir e passar no health).
   Cada operação `GET` vira comando de leitura; `POST/PUT/DELETE` viram comandos com `confirm: true` por padrão.
3. `--cmd` explícitos. Sem nenhum dos três: manifesto só com painel (sem tools) e uma dica de como acrescentar.

Nada é inferido de código-fonte.

### Manifesto gerado para a ferramenta de analytics

```json
{
  "apiVersion": 2, "id": "analytics", "name": "Analytics debug", "version": "0.1.0", "license": "private",
  "placements": ["canvas", "dock.right"], "defaultPlacement": "dock.right",
  "ui": "http://127.0.0.1:8767/",
  "service": { "base": "http://127.0.0.1:8767", "start": "./run.sh", "health": "/api/health",
               "cwd": "tools/page-load-metrics-live" },
  "commands": [
    { "name": "events", "summary": "Eventos de analytics recebidos", "runs": "http",
      "http": { "method": "GET", "path": "/api/document" }, "timeout": 30 },
    { "name": "clear_analytics", "summary": "Limpa o log de analytics", "runs": "http",
      "http": { "method": "POST", "path": "/api/clear/analytics" }, "confirm": true, "timeout": 15 }
  ],
  "events": ["analytics.event"],
  "eventStream": "/api/stream"
}
```

`service.cwd` é campo novo (a spec de Apps assume a raiz do cercado).

### Resultado grande do `events`

`GET /api/document` devolve tudo (performance, sistema, leaks, Perfetto). Para o agente, `events` precisa ser
filtrável. Dois campos novos opcionais em comandos `runs: "http"`:

- `result.pick`: lista de chaves do JSON de resposta a manter (`["analyticsEvents","analyticsEventCount"]`);
- `result.tail`: máximo de itens de um array (`analyticsEvents`, `50`), do fim para o começo.

Sem isso, o agente recebe megabytes de JSON irrelevante. Os limites do corpo (≤ 1 MiB) continuam valendo.

### SSE com snapshot completo (decisão a tomar)

`/api/stream` envia o documento inteiro a cada ingest; acima de 64 KiB o evento é descartado, então o aviso
"evento novo de analytics" pararia de chegar quando o log crescer. Opções:

- **A. Derivar o aviso do documento (recomendada):** manifesto novo `eventStream.diff: "analyticsEvents"`. O
  daemon guarda o último array visto e emite um aviso `analytics.event` só para itens novos (limite por rajada,
  ordem preservada). Eventos acima de 64 KiB continuam descartados, mas o diff sai do documento recebido: se o
  documento não couber, cai para um poll de `events` (`result.tail`) a cada N segundos.
- B. Pedir à ferramenta um SSE por evento. É mudar o repo do dono; fora de escopo.
- C. Sem eventos; o agente consulta `events` quando quiser. Mais simples, perde "aviso na hora".

### Modo consulta (2026-11-15, pedido do dono)

O dono quer o painel como fonte de **consulta**: evento de app não acorda o agente por padrão.

- Manifesto: `notify` opcional (bool). Sem o campo, `true` (manifestos v2 existentes seguem avisando).
  `collie app adopt` grava `notify: false`; `--notify` liga. Com `false`, o evento continua gravado
  (`collie app event <seq>`, `collie events`), só não vira aviso digitado. O cartão de aprovação diz se o app avisa.
- Consulta nos comandos `runs: "http"` `GET`: o daemon aplica, depois de `pick`/`tail`, `--last N` (os últimos N de
  cada lista), `--since last` (só itens depois do último que este terminal leu; cursor por terminal + cercado + app +
  comando, em memória, anda a cada leitura) e `--match <texto|regex>` (itens com algum campo string, em qualquer
  nível, que casa; sem diferenciar maiúsculas; regex inválida vira texto). Nunca vão para o app; um comando que
  declara um desses parâmetros fica com o dele.

### Segurança

- Cartão de aprovação em pt-BR mostra: nome, base, comando de start, `cwd`, comandos (com `confirm` marcados),
  eventos. Aviso extra quando `start` roda um script (mostra o caminho) ou o serviço escuta fora do loopback
  (detectado depois de subir, via `lsof`; só informativo).
- O `adb reverse` do `run.sh` não é do Collie; o cartão diz "este script pode alterar a conexão do emulador".
- `start` roda no sandbox do terminal do cercado, com rede liberada (decisão do dono, spec de Apps).
- Pin SHA-256 do manifesto e de `collie.json`; mudança pede aprovação de novo.

## Design — fase 2 (esboço, detalhar antes de construir)

- Novo plug-in embutido `ui` (painel `WebPluginPanel` sem rede, CSP fechada, só a ponte `window.collie`).
- `collie ui show --spec <json|arquivo>` e `collie ui show --html <arquivo|->`; `collie ui update <id> --data`;
  `collie ui close <id>`. Painel nasce com `createdBy` = terminal que chamou, em `nearestFreeFrame`.
- Spec declarativa (versão 1): `table`, `list`, `chart`, `form`, `buttons`, `text`, `code`, `status`. Cada ação
  tem `id`. Ação do usuário → aviso ao agente (dado do app). O agente responde com `ui update`.
- Fica de fora: persistência no cercado (a UI é efêmera) e aprovação (só para painéis que tentam algo além da
  ponte).

## Decisões do usuário

- Fase 2: abordagem **C**.
- Primeiro caso: ferramenta local de analytics, servidor web local.
- Prioridade: anexar a ferramenta de forma simples (fase 1 antes da fase 2).

## Minhas chamadas (conferir)

- Fase 1 antes da fase 2, porque o caso real do dono já cabe nos Apps.
- `app adopt` gera manifesto v2 comum (sem modelo novo); `confirm` por padrão em escritas.
- Descoberta por `collie.json` → OpenAPI → `--cmd`; nada de varrer código-fonte.
- `service.cwd`, `result.pick/tail` e `eventStream.diff` como campos opcionais novos do manifesto.
- Padrão `dock.right` para o painel da ferramenta de analytics.
- `.collie/apps/<id>/` versionado com o repo do dono; se ele preferir não commitar, `app adopt --local` grava
  só no cercado.

## Fica para quem construir

- Formato exato dos campos novos e mensagens de erro.
- Como o `diff` do SSE identifica itens novos (por posição, por `receivedAt` ou por hash).
- Teste de ponta a ponta: uma ferramenta de exemplo mínima (servidor com `/api/health`, `/api/document`, SSE)
  em `Tests/` ou `scripts/`, sem depender do repo do dono nem de Go.
- Os PRs de exemplo por ID, quando houver acesso ao repositório do dono com aprovação dele.

## Riscos

- O contrato real da ferramenta de analytics pode mudar no repo do dono; `collie.json` na pasta dela é a defesa.
- OpenAPI mal feito gera comandos ruins; por isso o cartão lista cada comando antes da aprovação.
- `run.sh` exige Go instalado; se faltar, a supervisão mostra o erro do script e a dica.
