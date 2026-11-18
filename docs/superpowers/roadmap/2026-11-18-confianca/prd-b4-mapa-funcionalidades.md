# PRD B4: mapa de funcionalidades

## Problema

Quando o dono diz "o menu … do terminal" ou "o painel de rede", o agente procura no código pelo nome que imagina. A
palestra: um "feature map", o sitemap do app do ponto de vista do usuário, dá vocabulário comum e diz ao agente que
superfície verificar em runtime. O Collie já tem o resto da verificação em runtime (`check --screen`, dispositivos,
painéis, `run-isolated.sh`); falta o mapa.

## Objetivo

1. `docs/feature-map.md` do próprio Collie: cada superfície que o usuário vê, com o nome que aparece na UI (português),
   onde está no código, e como verificar.
2. Mantido vivo por checagem: painel novo sem entrada no mapa falha o lint.
3. Produto: o laço avisa o agente quando o repo tem um mapa, para qualquer projeto que adote o arquivo.

## Não-objetivos

- Formato estruturado (JSON/YAML) ou ferramenta MCP nova. Markdown; a ingestão de docs da memória (`DocIngest`,
  `memory doc-search`) já o torna pesquisável.
- Gerar o mapa automaticamente.

## Requisitos

1. `docs/feature-map.md`, uma seção por superfície: canvas, cada painel (`Sources/ColliePlugins/*Panel.swift`),
   menus e cartões do app, grupos da CLI (`collie <grupo>`). Por seção: nome na UI, para que serve, arquivo(s),
   como verificar (comando, `check --screen`, ou passo à mão).
2. `scripts/ci/lint.sh` ganha a regra `feature-map`: todo `Sources/ColliePlugins/*Panel.swift` precisa ter seu nome de
   arquivo (sem extensão) citado em `docs/feature-map.md`. Não entra no baseline (não há exceção).
3. Prompt da tentativa do laço (`WorkLoop.prompt`): se a worktree tem `docs/feature-map.md` ou `FEATURES.md`, uma
   linha: "O mapa de funcionalidades do projeto está em <caminho>: use os nomes dele." Nada se não houver.
4. `docs/referencia.md`: uma linha sobre a convenção.

## Medida de resultado

- Pedido do dono em linguagem de UI ("o botão X do painel Y") resolvido pelo agente sem perguntar onde fica.

## Tarefas

- B4.1 mapa + regra no lint (`tasks/b4-1-feature-map.md`)
- B4.2 linha no prompt do laço (`tasks/b4-2-feature-map-prompt.md`)
