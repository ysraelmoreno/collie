# Device: OCR como fallback da árvore de UI

Data: 2026-11-22 · Estado: proposta com medições. Vem depois de `2026-11-22-device-helper-design.md` (H1 a H5): esta é a tarefa H6.

## Problema

A árvore de acessibilidade (helper ou `uiautomator`) não cobre tudo: jogos e `SurfaceView`, `<canvas>` em WebView, Flutter,
Compose sem semântica e telas feitas só de desenho têm quase nenhum nó rotulado. Nesses casos `device screen|find|tap
--text` ficam cegos e o agente volta a depender de imagem. O OCR local lê o texto do screenshot e devolve posições.

## Medições que sustentam esta spec (emulador API 37, 2026-11-22)

Vision (macOS) em processo residente, imagem 720×1280, com a máquina sob carga de um laço:

| Modo | 1ª chamada (modelo frio) | Seguintes |
|---|---|---|
| `fast` | 124 ms | 14 a 32 ms (mediana ~22) |
| `accurate` | 709 ms | 90 a 205 ms (mediana ~160); ~95 ms com a imagem a 0,5x |

Medidas anteriores de 540 a 1.625 ms eram partida de processo e modelo frio. Tesseract: 2.061 ms.

Qualidade, em dois corpus:

| Corpus | Modo | Recall de texto | Posição certa | Obs. |
|---|---|---|---|---|
| 6 telas reais estáveis (BEES, launcher, Settings; 81 textos, gabarito = árvore do helper) | `fast` | 89% | 100% (76/76) | errou texto pequeno |
| idem | `accurate` | 94% | 99% (79/80) | errou nomes de apps do launcher: texto claro sobre papel de parede |
| fixture `com.collie.fixture` (12 telas, 56 textos, pt-BR, claro e escuro, árvore pobre) | `fast` e `accurate` | 100% | n/a | corpus sintético e limpo |

Fixture (`Helpers/android-device/fixture/`, instalado no emulador, uma tela por intent
`--es screen canvas|surface|webcanvas|hidden|photo|normal [--ez dark true]`): nas telas de árvore pobre a árvore tem
**1 nó rotulado** (só a barra de ação) contra 5 a 6 na tela normal, e o OCR recuperou todo o texto. O "+" desenhado sem
texto continua invisível ao OCR. Com o helper, a tela `hidden` (views com `NO_HIDE_DESCENDANTS`) não é pobre, porque o
helper liga `flagIncludeNotImportantViews`.

O número honesto de recall em apps reais fica entre os dois corpus: 89 a 94% medido; 100% só em tela sintética.

## Objetivo

`device screen`, `find` e `tap --text` passam a usar OCR quando a árvore é pobre, devolvendo texto com posição marcado como
vindo do OCR, sem custo e sem mudança de saída quando a árvore é boa.

## Fora de escopo

Ícone sem texto (o OCR não vê; ficam o `id` da árvore, e para agentes com visão o screenshot com caixas numeradas, outra
spec); modelo de visão; iOS no primeiro corte (o Simulator tira screenshot por `simctl io`, a mesma ideia depois);
Linux e Windows (interface `OCRProvider` com tesseract é desenhada aqui, implementada depois).

## Desenho

### O1. Provedor de OCR

- `OCRProvider` (protocolo em `Sources/CollieDevice/OCR.swift`): `recognize(png: Data, level: fast|accurate, languages:
  [String]) async throws -> [OCRItem]`; `OCRItem {text, confidence, box: CGRect em pixels da imagem}`.
- Implementação macOS: Vision (`VNRecognizeTextRequest`), `recognitionLanguages` = `["pt-BR","en-US"]` (configurável),
  `usesLanguageCorrection` só no `accurate`. Roda **dentro do `collied`** (que já é só macOS e já linka frameworks do
  sistema); uma instância residente por daemon, com um reconhecimento de aquecimento no primeiro uso (o modelo frio custa
  120 a 700 ms, o aquecido 14 a 200 ms). Fila serial, uma imagem por vez.
- Sem provedor (outra plataforma, framework ausente): `OCRProvider` indisponível, e tudo cai na árvore.

### O2. Gatilho (quando o OCR roda)

Calculado sobre a árvore já lida, sem custo extra (meta < 5 ms). Roda se **qualquer um**:
1. **Poucos rótulos:** nós rotulados na área de conteúdo (fora da barra de status e da barra de ação) < 3.
2. **Cobertura baixa:** a área da tela coberta por nós rotulados ou clicáveis < 15% (pontos de partida; calibrar no corpus).
3. **Classes opacas dominantes:** um `SurfaceView`/`GLSurfaceView`, `WebView` sem filhos rotulados ou `FlutterView` cobre
   > 50% da tela.
4. **`find`/`tap --text` sem resultado na árvore:** OCR só nessa chamada (e na região, se `--region`).
5. **Pedido explícito:** `device screen --ocr`; `--no-ocr` desliga tudo.

Nunca roda se o screenshot vier preto ou uniforme (tela `FLAG_SECURE`) ou se o provedor estiver indisponível.
No fixture, 1 nó rotulado nas telas pobres contra 5 a 6 na normal: o gatilho 1 já separa os dois grupos; os limites
reais precisam de apps de verdade.

### O3. Fusão com a árvore

- Cada item do OCR com `confidence >= 0,5` e texto de 2 ou mais caracteres vira nó `source: "ocr"`, `role: "text"`,
  `clickable: false` (o OCR não sabe), com `bounds` e `ref` próprios.
- Descartar o item se seu centro cair dentro de um nó rotulado da árvore (a árvore ganha) ou se o texto for igual ao
  de um nó vizinho (< 24 px).
- Em `device screen`, os itens entram no grupo "Conteúdo" com marca `(ocr)`; em `--json`, `source:"ocr"`.
- Ordem de leitura: por linha (agrupar por centro vertical, depois esquerda → direita) para o texto sair legível.

### O4. Ações sobre itens do OCR

- `tap --text`/`find` casam também com itens do OCR (mesma ordem de casamento de M3/F1); o toque vai no **centro da caixa**.
- A resposta diz `via: "ocr"` e o aviso "sem confirmação de clique"; o agente usa `--then screen` para conferir.
- `--role` ignora itens do OCR (sem papel); `--region x1,y1,x2,y2` limita o OCR a um retângulo (mais rápido e preciso).

### O5. Custo e privacidade

- Captura: `screencap` (~150 ms) já existe; o helper pode servir a imagem pelo mesmo canal depois.
- Imagem reduzida a 0,5x no `fast`; cheia no `accurate` (padrão do fallback). Meta ponta a ponta: `screen` com fallback
  ≤ 500 ms.
- A imagem vive em memória ou num temporário apagado ao fim; nada persiste nem sai da máquina.
- `--timing` ganha `ocrMs`, `ocrLevel`, `trigger` (qual regra disparou).

## Arquivos

- Novo: `Sources/CollieDevice/OCR.swift` (protocolo, item, fusão, gatilho: puro e testável),
  `Sources/CollieDaemonKit/Devices/VisionOCR.swift` (Vision), `Helpers/android-device/fixture/` (o app de teste).
- Alterados: `DeviceService.swift`, `+Android.swift` (captura e fusão), `Plugins.swift` (`--ocr`, `--no-ocr`, `--region`),
  `ScreenModel.swift` (grupo com itens do OCR), `docs/referencia.md`, `docs/feature-map.md`, `CollieOrientation.swift`.

## Tarefas para o laço (após H5)

| # | Tarefa | Depende de |
|---|---|---|
| H6a | `OCR.swift`: protocolo, gatilho e fusão puros, com testes de unidade sobre árvores e itens de exemplo (inclui as árvores do fixture) | H5 |
| H6b | `VisionOCR` no `collied` (residente, aquecimento, fila) e ligação em `device screen` com `--ocr/--no-ocr/--region`, com `OCRProvider` falso nos testes | H6a |
| H6c | `find`/`tap --text` por OCR, `--timing`, docs e orientação | H6b |

Cada uma commita ao final; sem scope (cartão de 1500 caracteres).

## Testes

- **Sem aparelho:** gatilho (cada regra, borda de 3 nós e de 15%), fusão (árvore ganha, descarte por proximidade, ordem
  de leitura, confiança mínima), `OCRProvider` indisponível cai na árvore, imagem preta não dispara.
- **Com fixture e emulador (manual, com o bundle instalado):** o script `scripts/ocr-corpus-eval.py` captura as telas
  do fixture e dos apps de teste, mede recall, itens extras, posição e latência. Rodado pelo dono; o laço não alcança o
  aparelho.

## Critérios de aceite

| # | Critério | Meta |
|---|---|---|
| 1 | Gatilho | dispara em ≥ 90% das telas de árvore pobre e em < 5% das de árvore boa, num corpus de ≥ 30 telas de ≥ 5 apps (hoje: 6 telas reais e 12 do fixture) |
| 2 | Recall de texto | ≥ 90% com `accurate` (medido: 94% em app real, 100% no fixture); ≥ 85% no `fast` |
| 3 | Precisão | ≥ 90% dos itens são texto real (barra de status conta como texto real) |
| 4 | Posição | o toque no centro da caixa acerta ≥ 95% (medido 99 a 100%), conferido pela mudança da tela |
| 5 | Latência | OCR ≤ 250 ms no `accurate` e ≤ 40 ms no `fast`, residente e aquecido; `screen` com fallback ≤ 500 ms; 1ª chamada ≤ 1 s |
| 6 | Sem regressão | árvore boa: saída idêntica à de hoje e custo do gatilho < 5 ms |
| 7 | Degradação | OCR indisponível ou com erro: comandos funcionam, `screen` mostra `ocr: unavailable` |
| 8 | Privacidade | nenhuma imagem persistida; tela preta ou `FLAG_SECURE` ignorada |

## Riscos

- **Corpus pequeno e sintético:** os 100% do fixture não valem para apps reais; os 89 a 94% de apps reais vêm de 6 telas de
  3 apps em inglês. Falta pt-BR real, apps densos, Flutter, Unity e Compose sem semântica. Ampliar o corpus é parte do
  aceite (critério 1).
- **Texto sobre imagem e texto pequeno:** foi onde o OCR errou nos apps reais (nomes de apps no launcher; "Modes" no
  `fast`). Mitigação: `accurate` por padrão e `--region` na busca.
- **Falsos disparos:** telas com pouco texto de verdade (um mapa, uma foto) podem acionar o OCR sem necessidade; o custo é
  ~160 ms, não um erro.
- **Sem papel e sem clique:** itens do OCR não dizem se algo é botão; `tap` por OCR pode tocar em texto que não responde.
  O `--then screen` do agente é a confirmação.
- **Plataformas:** Vision só no macOS. Linux e Windows exigem `tesseract` (2 s no teste, menos preciso) ou outro motor;
  decisão adiada para a spec de plataformas.
