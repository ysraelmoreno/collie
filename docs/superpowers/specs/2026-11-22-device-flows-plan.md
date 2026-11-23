# Device: o agente aprende os fluxos do app (plano e decisão de arquitetura)

Data: 2026-11-22 · Estado: plano aprovado pelo dono; nada implementado. Cartões no Quadro: pai `22f022c1`, P1 `9db924b5`, spike `9223f28e`,
core `424f29b5`, P2 `66be6c2c`, P3 `b683a312`. Ordem: depois da F2 da Fábrica.

## Objetivo
Um agente entende "Navegue para a tela de checkout" sem o usuário guiá-lo, e o Collie aprende os fluxos de cada app para melhorar teste e depuração.

## Origem
Análise do repositório https://github.com/pierridotite/mobile-agent-testers (MIT, Python): testes exploratórios com agentes por persona (aparelho, idioma, fonte,
escuro) em paralelo; ferramenta única de "ver a tela" (screenshot, elementos com centros, crash desde a última chamada, checagem de acessibilidade); briefing de regras;
`report.md` e `findings.json`; agregador que junta duplicatas (103 relatos, 46 bugs distintos). Ele não aprende entre execuções. (Lidos: README, AGENT_BRIEF.md e
`scripts/android/screen.py`; não lidos: scripts de execução, `personas.json` e o agregador.)

## Ideia central: um grafo do app
Nó = assinatura estável de tela (título, aba, rótulos e ids fixos; ignora números, preços e listas variáveis). Aresta = ação semântica (tap --text, rolar, digitar) com
assinatura antes e a esperada depois, condições (login, carrinho, flags) e a versão do app. Metas nomeadas (checkout, login) apontam para nós. O LLM escolhe QUAL meta; o
caminho é determinístico (menor trajeto, cada passo com `--then screen` conferindo a pós-condição); se a tela não bate, o agente explora e corrige o grafo. Um fluxo
gravado vira regressão reexecutável.

Aprendizado, em ordem de segurança: (1) passivo, das corridas dos agentes; (2) gravação explícita e opt-in pelo painel (o painel já media a entrada do usuário; a senha
já sai mascarada pelo helper); (3) nunca vigilância em segundo plano sem pedir.

## Decisão de arquitetura (dono, 2026-11-22)
O conhecimento (grafo, planejador, fluxos gravados, agregador, relatórios, UI) vira um APP DE SERVIÇO do cercado, no modelo do Quadro (`Examples/apps/quadro`: `collie.json`
com comandos para agentes, servidor próprio, UI, fluxo de eventos), mais skills para as regras e os modos. O daemon fica só com o que exige privilégio ou velocidade.

| Peça | Onde | Por quê |
|---|---|---|
| P1: assinatura de tela, log de crash desde a última leitura, checagem de acessibilidade em `device screen` | daemon | propriedades do `device screen`; o log exige adb e simctl e o "desde a última leitura" |
| `device.action` (ação, assinatura antes e depois, origem, instante, senha mascarada) | daemon | única ponte para gravar o que o usuário faz no painel |
| `device run` (lista de passos com a assinatura esperada, para na divergência) | daemon | executor genérico e determinístico (o "lote de ações" adiado) |
| `device persona apply` (fonte, escuro, idioma, tamanho por adb e simctl, com desfazer) | daemon | precisa dos comandos do aparelho |
| Grafo, planejador (`flow go` devolve o plano), gravação, `replay`, UI, agregador, relatórios | app de serviço "Fluxos" | ciclo de vida independente: mudar o daemon exige bundle e instalação que fecham os terminais; superfície menor; opcional |
| Regras do briefing, modos reproduzir bug e comparar versões, fan-out de personas | skills e o app | texto e orquestração que já existe (summon, coleira) |

Plug-in v1 não serve sozinho: webview trancado, sem rede, sem projeto, e sem chamar comandos do daemon (helpers e permissões são as fases 2 e 3).

## Pergunta em aberto que decide tudo (spike `9223f28e`, prioridade alta)
Um app de serviço, sob o sandbox do cercado, consegue (1) falar com o `collied` e chamar `collie device screen|tap`; (2) assinar um fluxo de eventos do daemon (hoje há
`ui.events` e `work.*`, falta `device.action`); (3) que permissões precisaria e como o usuário as aprova (capacidade nova, tipo a fase 3 de permissões); (4) qual a latência de
ida e volta; (5) se não der sem abrir buraco no sandbox, qual a menor parte que volta para o daemon. O Quadro não faz nada disso: não há precedente.

## Riscos
1. A assinatura de tela estável com conteúdo dinâmico é a parte difícil: medir em 3 a 5 apps reais (no BEES os test tags do Compose ajudam).
2. Estado (login, carrinho, feature flags) exige condições nas arestas e a versão do app no grafo.
3. Grafo velho: a regra "tela não bateu, explora e atualiza" precisa de teste.
4. Ação destrutiva (Finalizar pedido, Excluir, Pagar) por um caminho decorado: confirmação ou ambiente de teste.
5. Gravar a entrada do usuário: privacidade; sempre opt-in.

## Ordem
P1 e o spike primeiro; depois "Fluxos core" (daemon, exige revisão independente antes do bundle); depois P2 (app) e P3 (personas, agregador, modos).
