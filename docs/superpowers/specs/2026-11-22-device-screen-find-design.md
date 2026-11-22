# Device: descrição da tela e busca por objetivo (spec da onda seguinte)

Data: 2026-11-22 · Estado: proposta. Depende da spec `2026-11-21-device-agent-loop-design.md` (M1 a M4) estar integrada.

## Objetivo

O dono quer dizer ao agente "navegue para a aba Combos e ache o produto X" sem exemplificar o caminho. Hoje (e depois
de M1 a M4) o agente ainda planeja tudo: abre, rola, confere. Um modelo fraco (Cursor com Composer 2.5) falha no
planejamento, não só na percepção. Esta onda move para o daemon a percepção agrupada e os trechos repetitivos
(rolar até achar, esperar a tela estabilizar), deixando ao agente decisões de uma linha.

## Pré-requisito: medir antes (critério 0)

M1 a M4 mudam o custo de cada passo. Antes de implementar esta onda:
1. Instalar o bundle com M1 a M4 e repetir com o Cursor (Composer 2.5) a tarefa "Continue to App → + → Open Deals".
2. Registrar: passos, tempo total, se gerou script Python.
3. Se já concluir sem script e em tempo aceitável, esta onda cai para S1 e S3 (o resto vira opcional).

## Fora de escopo

`device do "<objetivo em linguagem natural>"` (agente interno barato que planeja e executa). Só abrir uma onda para ele
se, depois desta, o Cursor ainda não completar objetivos de 3 passos. Também fora: legenda por visão (OCR ou modelo)
para nós sem rótulo, e qualquer mudança no painel de device.

## Mudanças

### S1. `device screen`: a tela em grupos

Comando novo, ao lado de `device ui` (que continua sendo a árvore).

**Saída (texto, padrão):**
```
Tela: Offers   [voltar]
Abas: [Points*] [Combos]
Ações: [Filter]
Conteúdo (rolável): "Something went wrong", [Try again]
Flutuante: [+] configuration fab, topo direito
Mudou: título Home → Offers
```
`--json` devolve o mesmo em `{title, back, tabs[], actions[], fields[], lists[], floating[], changed[]}`, cada item com
`ref`, `label`, `role`, `state` (`selected|checked|disabled|focused`).

**Modelo (`Sources/CollieDevice/ScreenModel.swift`, puro, testado sem aparelho):**
- Entrada: os `UINode`s. Hoje `UINode` não tem pai nem estado; adicionar `parent: Int?` (derivado de `depth` na
  ordem da lista), e `selected`, `checked`, `enabled`, `focused`, `scrollable` (Android: atributos do XML que o
  `UITree.Handler` hoje descarta; iOS: `AXValue`/`enabled` do AXe).
- Papéis a partir da classe: Android `Button`/`ImageButton` → botão, `EditText` → campo, `RecyclerView`/`ListView`/
  `ScrollView`/nó `scrollable` → lista; iOS `Button`, `TextField`, `Tab`, `Cell`, `ScrollView`, `NavigationBar`.
  Compose não tem classe útil (tudo `View`): usar `id` (`*tab*`, `*toolbar*`, `*fab*`, `*search*`) e o clique.
- Título: texto do nó de toolbar (id ou classe `NavigationBar`/`Toolbar`), senão o primeiro texto no topo (y < 15% da
  altura).
- Abas e escolhas: 2 a 6 irmãos clicáveis na mesma linha (|Δy| pequeno), rótulos curtos; marcar o `selected`.
- Flutuante: clicável pequeno encostado numa borda, sem rótulo ou com só ícone. Rótulo vem de `id` humanizado
  (`configuration_fab` → "configuration fab") e posição ("topo direito").
- Resto clicável vira "Ações"; campos vão em "Campos"; o que sobra de texto na área rolável vira "Conteúdo", cortado
  em N itens (padrão 12) com "+K itens: use device ui".
- `changed`: o daemon guarda por painel a última `screen` e compara título, abas selecionadas e contagem de itens.
  Sem tela anterior, a seção some.
- `--all`: junta a árvore crua de `device ui --all` (para depurar o agrupamento).

Heurísticas erradas são esperadas em apps reais. Por isso `screen` nunca esconde: o que não encaixa em grupo cai em
"Ações" ou "Conteúdo", e `device ui` continua disponível.

### S2. `device find <texto>` com rolagem

- `device find <texto> [--scroll] [--dir down|up] [--max <n>] [--role tab|button|field] [--then screen]`.
- Casamento igual ao de `tap --text` (M3): igual primeiro, depois "contém", sem caixa; `--role` filtra pelo papel do S1.
- Sem `--scroll`: uma árvore, devolve `{found, ref, label, role, center, clickable}` ou `notFound`.
- Com `--scroll`: laço de no máximo `--max` (padrão 8) rolagens. Cada volta: dump, procura; se não achou, desliza
  de 75% a 35% da altura (Android pixels, iOS pontos) e espera `settle`. Para quando acha, quando a árvore fica
  igual à anterior (fim da lista) ou no máximo. Devolve também `scrolls` e `endReached`.
- Os refs ficam válidos depois do `find`: o agente faz `tap --ref` sem outro `ui`.
- Erro: `notFound` com `scrolls`, `endReached` e até 5 rótulos parecidos.

### S3. `device wait`

- `device wait [--text <t>] [--gone] [--stable] [--timeout <s>]` (padrão 10 s, máximo 60).
- `--text t`: espera o texto aparecer (ou sumir, com `--gone`). `--stable`: espera duas árvores seguidas iguais.
- Devolve `{ok, waitedMs}`; `timeout` vira erro `.timeout` com a última tela resumida.
- Substitui `sleep` + `ui` do agente e resolve a transição "Signing in..." vista no teste.
- M2 (`--then ui`) ganha `--then screen`/`--settle stable` reaproveitando o mesmo `wait --stable`.

### S4. Dump mais rápido

Medido hoje: `device ui` 2,2 a 3,3 s, e `find --scroll` multiplica isso por volta.
- Passo 1 (barato): `uiautomator dump /dev/tty` via `adb exec-out`, em vez de gravar em `/sdcard` e fazer `cat`
  (corta uma chamada de adb). Medir antes e depois; se não passar de ~10%, não vale manter.
- Passo 2 (só se o passo 1 não bastar): sessão persistente. Android: auxiliar residente (a avaliar: `uiautomator2`,
  serviço de acessibilidade próprio); iOS: conferir se o AXe tem modo persistente ou em lote (não verificado).
  Avaliar custo de dependência e de instalação antes de decidir; não fazer sem aprovação do dono.
- Instrumentação: `device ui|screen|find --timing` devolve `timingMs` por etapa (adb, parse, agrupamento), para
  medir sem cronometrar de fora.

### S5. Orientação

A linha de Device (M4) passa a dizer: `device screen` para ver, `find "X" --scroll` para achar, `tap --text X --then
screen`, `wait --text X`; `screenshot` só se `screen` e `ui` não mostrarem o elemento. Mesmo teto de 1500 caracteres.

## Arquivos

- `Sources/CollieDevice/UITree.swift` e `AXeTree.swift`: pai e estados no `UINode`.
- `Sources/CollieDevice/ScreenModel.swift` (novo): agrupamento e texto.
- `Sources/CollieProtocol/Plugins.swift`: `device.screen`, `device.find`, `device.wait` e os parâmetros novos.
- `Sources/CollieDaemonKit/Devices/DeviceService.swift`, `+Android.swift`, `+iOS.swift`: um `observe()` e um
  `resolve()` compartilhados (já planejados em M2/M3); `find` e `wait` entram sobre eles.
- `Sources/CollieDaemonKit/CollieOrientation.swift`, `docs/referencia.md`, `docs/feature-map.md`.

## Tarefas para o laço (cada uma com check em `scripts/check-device-loop2.sh`)

| # | Tarefa | Depende de |
|---|---|---|
| E1 | `UINode` com pai e estados, `ScreenModel` e `device screen` (Android e iOS) | M1 a M4 |
| E2 | `device wait` e `--settle stable` | E1 |
| E3 | `device find` com `--scroll` e `--role` | E1, E2 |
| E4 | Dump por `/dev/tty`, `--timing` e medição antes/depois | E1 |
| E5 | Orientação e docs | E3 |

Todas tocam `Plugins.swift` e os `DeviceService`: não rodam em paralelo (o teto de 1500 caracteres do cartão também
derrubou o paralelismo da onda anterior; preferir `--check` com script e escopo ausente).

## Testes (só com `--filter`)

- `ScreenModelTests` (novo, sem aparelho): árvore de exemplo da tela Offers medida em 2026-11-21 (título, abas
  Points*/Combos, botão flutuante sem rótulo, lista vazia) produz o texto esperado; fixture do XML real em
  `Tests/Fixtures`.
- `DeviceCommandTests`/`SimCommandTests`: `find` com rolagem (fim de lista, achou na 3ª volta, `--max`), `wait`
  (aparece, some, timeout, estável), `--role`.
- Orientação: linha nova cabe no teto nas formas normal e curta.

## Critérios de aceite

1. `device screen` na tela Offers do emulador de teste devolve título, abas com a selecionada e o botão flutuante com
   rótulo legível, em no máximo 12 linhas.
2. `find "Combos" --role tab` e `tap --text Combos --then screen` levam de Offers à aba Combos em 2 chamadas.
3. `find "<produto>" --scroll` acha um item abaixo da dobra de uma lista real, ou devolve `endReached`.
4. Cursor (Composer 2.5) cumpre "vá para a aba de Combos e ache o produto X" sem exemplo de caminho e sem script
   Python. Se não cumprir, abrir a onda de `device do`.
5. S4 mede o antes e o depois do dump; a decisão do passo 2 é do dono.

## Riscos

- Agrupamento errado esconde ou mistura elementos (Compose sem semântica, WebView, jogos, canvas): `screen` mantém
  `ui --all` como saída crua e não descarta nada que não encaixe. Medir em 3 a 5 apps reais antes de congelar as
  heurísticas; este app de teste (BEES) é um só.
- `find --scroll` rola a tela e pode disparar efeitos (pull-to-refresh, carrossel que avança sozinho): limitar o gesto
  à região do conteúdo e deixar `--max` baixo.
- O dump de 2,2 s por volta faz uma busca de 8 rolagens levar ~20 s se S4 não ajudar.
- O laço usa o daemon instalado: o dono precisa instalar o bundle para validar no emulador.
