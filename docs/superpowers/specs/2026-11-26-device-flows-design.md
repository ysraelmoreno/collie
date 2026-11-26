# Fluxos do app no device — design

Status: rascunho para o dono aprovar (2026-11-26). Nada implementado. Detalha, sem trocar a decisão de arquitetura do dono
(2026-11-22: o conhecimento vira um app de serviço, o daemon só oferece primitivas), o plano
`2026-11-22-device-flows-plan.md`. Responde, **pela leitura do código e sem medir**, a pergunta do spike `9223f28e`.

## Intenção e porquê

O dono quer que um agente entenda "navegue para a tela de checkout" sem ser guiado passo a passo, e que o Collie aprenda os
fluxos de cada app para melhorar teste e depuração. Hoje o agente refaz a exploração do zero a cada pedido: `device screen`
mostra a árvore, o agente decide cada toque, e nada fica de uma corrida para a seguinte.

## Metas

- "Vá para <meta>" vira um caminho **determinístico** (menor trajeto num grafo do app); o modelo só escolhe qual meta.
- Cada passo confere a tela esperada; se a tela não bate, o agente explora e corrige o grafo.
- Um fluxo gravado é uma regressão reexecutável, sem modelo.
- O aprendizado nasce das corridas dos agentes (passivo) e da gravação explícita do usuário no painel (opt-in).

## Não metas

- Persona em paralelo, agregador de bugs e modos "reproduzir bug" e "comparar versões": é a fase P3, com spec própria depois.
- Vigilância em segundo plano sem pedido do usuário. Nunca.
- Substituir `device screen`/`tap`/`find`: continuam sendo a única forma de agir no aparelho.

## Anti-metas

- Um fluxo decorado executar uma ação destrutiva (Finalizar pedido, Excluir, Pagar) sem confirmação.
- A senha digitada aparecer no que se grava. O helper já a devolve mascarada; a gravação nunca pede o texto real.
- Abrir buraco no sandbox do cercado para o app falar com o daemon.

## Restrições

- O daemon só ganha o que exige privilégio ou velocidade; mudar o daemon exige bundle e instalação que fecham os terminais,
  e uma revisão independente antes do bundle (regra do projeto).
- Quem age no aparelho é sempre o agente ou o usuário, pelos comandos `collie device`; o app de serviço **não** age.
- Tudo que o app devolve ao agente é dado do app, nunca instrução (regra dos apps do cercado).

## O que o código já responde ao spike (não medido)

Contrato dos apps (`2026-11-08-paddock-apps-design.md`, `Examples/apps/quadro`): o app é um servidor em loopback que **o
daemon chama** (`runs: "http"`); o `eventStream` é o daemon lendo um SSE **do app**. Consequências:

1. **App → daemon (chamar `collie device screen|tap`):** não existe. O app não recebe `COLLIE_SOCKET`/token de terminal. Dar
   isso abriria justamente o buraco que a anti-meta proíbe. **Resposta: não, e não vamos abrir.**
2. **Daemon → app (eventos de device):** também não existe hoje (o daemon só assina o stream do app). Dá para criar, mas é um
   canal novo com garantias a desenhar (entrega, ordem, contrapressão).
3. **Pasta do cercado:** o app roda com a pasta do cercado e já lê e escreve nela (o Quadro guarda o estado ali). Um arquivo
   que o daemon escreve e o app lê não pede capacidade nova nem canal novo.

Medidas que ainda faltam (latência do caminho e custo de ler o arquivo) entram no teste de aceite da onda 2.

## Abordagens consideradas

- **A. Tudo no daemon** (grafo, planejador e gravação como comandos novos). Simples e rápido, sem capacidade nova. Custo: cada
  ajuste do grafo vira bundle e instalação que fecham os terminais; contraria a decisão do dono; o daemon cresce com produto.
- **B. App de serviço que age no aparelho** (o app chama `collie device`). É o desenho original do plano. Custo: exige uma
  capacidade nova (credencial de terminal ou ponte de comandos para apps) e um canal de eventos; ambos abrem superfície no
  sandbox. Só valeria depois de um spike que medisse e aprovasse isso.
- **C. App de serviço alimentado por arquivo, agente como ponte (escolhida).** O daemon ganha primitivas pequenas e um **log
  de ações em arquivo no cercado**; o app lê o log, monta o grafo e devolve **planos** (listas de passos); o agente executa o
  plano pelo executor do daemon (`device run`). O app nunca age no aparelho nem fala com o daemon.

C mantém a decisão do dono (conhecimento no app, daemon com primitivas) e não pede capacidade nova. O preço é o agente
carregar o plano até o `device run`, que é uma chamada a mais por meta.

## Design (abordagem C)

**Onda 1 — P1, no daemon (cartão `9db924b5`, 3 tarefas).**
1. `sig` em `device screen` e em `find`/`tap --then screen`: hash de título, aba selecionada, rótulos e ids fixos; ignora
   números, preços e itens de lista variável. Aparece na resposta e no `--timing`.
2. Log de crash desde a última leitura, impresso no `screen` como `ERROS DESDE A ÚLTIMA LEITURA` (logcat de crash e
   `AndroidRuntime:E`; log do simulador no iOS).
3. Checagem de acessibilidade a partir de bounds e descrição que o helper já devolve: controle clicável sem nome, alvo
   abaixo de 48 dp (Android) ou 44 pt (iOS), como linha de resumo.

**Onda 2 — executor e log, no daemon (cartão `424f29b5`, exige revisão independente antes do bundle).**
1. `device.action`: cada ação (agente ou painel) vira uma linha em `<cercado>/.collie/flows/actions.jsonl` com ação semântica,
   assinatura antes e depois, origem (`agent:<nome>` ou `panel`), instante e `app` (pacote e versão). Senha mascarada. Só liga
   por cercado, por escolha do usuário (opt-in), e o painel mostra quando está ligado.
2. `device run --plan <arquivo>`: executa a lista de passos; cada passo é uma ação com a `sig` esperada depois; **para na
   primeira divergência** e devolve o passo, a esperada e a obtida. Passo marcado `destructive` pede confirmação ao usuário
   (cartão no app), mesmo que um agente o execute.

**Onda 3 — app de serviço "Fluxos" (cartão `66be6c2c`).**
- Lê `actions.jsonl` e mantém o grafo (nó = `sig`; aresta = ação com `sig` antes e esperada depois, condições de estado e
  versão do app). Metas têm nome (checkout, login) e apontam para nós.
- Comandos para o agente: `flow goals`, `flow go <meta>` (devolve o plano, nunca executa), `flow record start|stop`,
  `flow learn` (reprocessa o log), `flow show <meta>`. Painel: grafo, metas e fluxos gravados.
- Regra de grafo velho: se `device run` parou numa divergência, o agente explora, e a nova aresta substitui a antiga com a
  versão do app; a velha fica marcada como obsoleta, não apagada.

**Fora desta spec (P3):** personas, agregador de relatos, modos reproduzir bug e comparar versões.

## Validação (critérios de aceite)

- **Onda 1** (do cartão): a assinatura da mesma tela em 5 leituras seguidas e em claro/escuro é igual em ≥ 95 %; telas
  diferentes dão assinaturas diferentes; medido no fixture, no BEES, em Configurações e no launcher. Crash provocado no
  fixture aparece na leitura seguinte. A checagem acha o botão sem rótulo do fixture. `device screen` continua < 60 ms com
  helper.
- **Onda 2:** num fixture, um plano de 5 passos roda até o fim; o mesmo plano com um passo que muda a tela esperada para na
  divergência certa; um passo `destructive` não roda sem confirmação; a senha nunca aparece no log (teste com campo de senha).
- **Onda 3:** depois de 3 corridas de agente no fixture, `flow go <meta>` devolve um plano que `device run` executa sem o
  modelo; mudar a versão do app e quebrar uma aresta faz o agente corrigir o grafo na corrida seguinte.
- **Passo do dono (roteiro manual):** (1) ligar o registro de ações num cercado e fazer um fluxo no painel do device; (2) ver o
  fluxo aparecer em Fluxos; (3) pedir a um agente "vá para <meta>" e comparar o número de chamadas com e sem o grafo.

## Riscos

1. Assinatura estável com conteúdo dinâmico é a parte difícil: medir em 3 a 5 apps reais antes da onda 2.
2. Estado (login, carrinho, feature flags) exige condições nas arestas.
3. O log cresce: rodízio por tamanho e idade, e o usuário pode apagar tudo de um cercado.
4. O arquivo é lido por um app; o conteúdo é dado (nomes de tela, textos), nunca instrução.

## Minhas chamadas (conferir)

- Abordagem C no lugar do app agindo no aparelho (B): reduz a superfície, mas o agente vira a ponte. Se você prefere que o
  app execute sozinho, B pede o spike medido e uma capacidade nova aprovada por você.
- Arquivo em `<cercado>/.collie/flows/actions.jsonl` como contrato entre daemon e app, sem canal de eventos novo.
- Gravação sempre opt-in por cercado, com indicador no painel.
- `flow go` só devolve plano; quem executa é o agente com `device run`.
- A onda 1 sai antes e sozinha: útil sem o resto e destrava a medida da assinatura.

## Deixado ao construtor

Formato exato do `sig` (hash e campos) dentro das regras acima; nome e forma dos campos do `actions.jsonl` e do plano; rodízio
do log; texto do cartão de confirmação de passo destrutivo; layout do grafo no painel.
