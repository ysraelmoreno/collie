# Device: ciclo curto para agentes (spec)

Data: 2026-11-21 · Estado: proposta, nada implementado.

## Problema

Agentes fracos (Cursor com Composer 2.5) não conseguem usar `collie device`: acabam escrevendo scripts em Python para
"ler" o PNG do `device screenshot`. Medido em 2026-11-21 num emulador Android (`emulator-5554`, tarefa "Continue to App →
+ → Open Deals"):

| Passo | Tempo |
|---|---|
| `device ui` (Android) | 2,2 a 3,3 s (4 amostras): `uiautomator dump` + `cat` do XML |
| `device tap --ref` | 0,1 s |
| Passo ver → agir | ~2,5 a 3,5 s, quase todo no `ui` |

Achados no mesmo teste:
- A árvore tem 49 a 67 linhas, a maioria `FrameLayout`/`ViewGroup`/`View` só com `id`. O botão "+" aparecia só como
  `Button id=configuration_fab`, sem texto: quem procura "+" por texto não acha.
- Depois de um `tap` o agente não sabe quando a tela mudou: precisa de `sleep` e de outro `ui`.
- A orientação injetada (`CollieOrientation.swift:103`) diz só "(screenshot, tap, logs)": não ensina a usar a árvore.

Hipótese ainda não confirmada: o Composer não recebe imagem como resultado de ferramenta. Confirmar lendo o transcript
de uma sessão do Cursor antes de dar a spec por fechada (critério de aceite 0).

## Fora de escopo

Sessão persistente de adb/AXe (corta o custo de 2,2 s do dump), lote de ações (`device run`), OCR ou transcrição
visual. São o próximo passo se as quatro mudanças abaixo não bastarem. Também fora: mudar o painel de device e o
formato dos eventos.

## Mudanças

### M1. `device ui` compacto por padrão

- `device ui` devolve só nós úteis: com `text` ou `desc` (rótulo), ou `clickable`. Nó só com `id` e sem clique sai.
- Nó clicável sem rótulo mostra o `id` e a classe (`[e4] Button id=configuration_fab (632,136) clickable`), como hoje.
- `device ui --all` devolve a árvore de hoje (para depurar).
- Os refs são atribuídos na árvore completa e só então filtrados: `e4` continua sendo o mesmo nó em `--all`, e
  `tap --ref` continua valendo. A numeração da saída compacta tem buracos (e1, e4, e9...); isso é aceitável.
- Vale para Android (`UITree.lines`) e iOS (`AXeTree`), que já compartilham `UINode`. Mudar `UITree.lines` ou adicionar
  um parâmetro `compact`; o filtro mora lá, sem tocar nos dois serviços.
- Resposta ganha `nodes` (quantos nós saíram) e `total`, para o agente saber que há mais com `--all`.

### M2. `--then ui` nas ações

- `tap`, `swipe`, `text`, `key` e `launch` aceitam `--then ui` (e `--settle <ms>`, padrão 400, máximo 3000).
- Depois da ação o daemon espera `settle`, roda o mesmo caminho de `device.ui` (atualiza `refs`) e devolve
  `{ "ui": { "tree": ..., "truncated": ..., "nodes": ..., "total": ... } }` além do `{}` de hoje.
- Sem `--then`, a resposta continua `{}`: compatível.
- Mantém 1 chamada por passo em vez de 2. O custo do dump (2,2 s) continua, mas some um round-trip do modelo.
- `--then` só aceita o valor `ui`. Outro valor: `invalidArgs`.

### M3. `tap --text` e `tap --id`

- `tap --text <t>` e `tap --id <id>` resolvem o alvo no daemon, sem `ref`. Exigem pelo menos um dos três: `x y`,
  `--ref`, `--text`/`--id`; mais de um: `invalidArgs`.
- Sempre fazem um dump novo (a árvore em cache pode estar velha; custo de 2,2 s, mas o agente não faz a chamada de
  `ui` à parte).
- Casamento: `--text` compara com `text` e `desc`, sem diferença de caixa, primeiro igual e depois "contém"; `--id`
  compara o `id` exato. Se o nó achado não é clicável, sobe ao ancestral clicável mais próximo (menor `depth` anterior
  na lista); se não há, toca o centro do próprio nó.
- Vários candidatos: `invalidArgs` com a lista dos refs e rótulos (no máximo 5), para o agente escolher com
  `--ref`. `--nth <n>` escolhe o n-ésimo (a partir de 1). Nenhum: `notFound` com até 5 rótulos parecidos.
- Aceita `--then ui` (M2).

### M4. Orientação ao agente

- A linha de Device em `CollieOrientation.swift` passa a ensinar o ciclo: `device ui` (árvore, não leia o PNG),
  `tap --text|--ref --then ui`; screenshot só se a árvore não tiver o elemento.
- O texto tem teto (`limit = 1500`, com formas curtas para Cursor): a linha nova substitui a de hoje, sem aumentar o
  total. Se não couber, a forma curta cai para só "collie device ui; tap --text … --then ui".
- A mesma dica vai para o `--help` de `device ui` e `device screenshot` ("o PNG é para você ver, não para parsear").

## Arquivos

- `Sources/CollieDevice/UITree.swift`: filtro compacto e `nodes`/`total`.
- `Sources/CollieProtocol/Plugins.swift:170-200`: parâmetros `--all`, `--then`, `--settle`, `--text`, `--id`, `--nth`.
- `Sources/CollieDaemonKit/Devices/DeviceService+Android.swift` e `+iOS.swift`: `then`, resolução por texto.
  Extrair `resolve(args:)` e `observe()` uma vez em `DeviceService` para não duplicar nos dois.
- `Sources/CollieDaemonKit/CollieOrientation.swift`: linha de Device.
- `docs/referencia.md` e `docs/feature-map.md`: comandos e flags.

## Testes (só os alterados ou novos, com `--filter`)

- `UITreeTests`: filtro compacto mantém rótulo e clicável, tira nó só com `id`; refs iguais com e sem `--all`.
- `DeviceCommandTests` e `SimCommandTests`: `tap --text` (único, ambíguo, `--nth`, não achado, sobe ao ancestral),
  `--then ui` devolve árvore e atualiza `refs`, argumento inválido.
- `CommandsTests` (protocolo): novos parâmetros listados.
- Orientação: teste que a linha nova cabe no teto nas formas normal e curta.
- Não rodar a suíte completa. `MCPTests.mcpListsTools` já falha no baseline: não é regressão.

## Critérios de aceite

0. Transcript do Cursor confirma a hipótese do Python, ou a spec é revista (o que ele realmente tentou).
1. No emulador, a tarefa "Continue to App → + → Open Deals" roda em 3 chamadas (uma por clique, cada uma com
   `--then ui`) e sem `ref` nem `sleep` do agente.
2. A saída compacta do mesmo ponto tem no máximo metade das linhas da árvore de hoje.
3. `tap --text "Open Deals"` funciona sem `ui` anterior.
4. Mesma tarefa com o Cursor (Composer 2.5): conclui sem gerar script Python. Se ainda gerar, abrir a próxima onda
   (sessão persistente e transcrição visual).

## Riscos

- Compactar a árvore pode esconder um nó que o agente precisava: `--all` e o contador `nodes`/`total` mitigam.
- `--then ui` com `settle` fixo pode pegar a tela no meio de uma animação ("Signing in..." foi visto no teste). O agente
  pode repetir `ui`; uma espera por estabilidade fica para depois.
- O laço roda o código do daemon instalado: testar o comportamento novo exige bundle novo instalado pelo dono.
