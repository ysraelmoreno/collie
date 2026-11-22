# Relatório: corpus iOS do fixture (OCR e árvore) — 2026-11-22

Fixture: `Helpers/ios-device/fixture/` (bundle `com.collie.fixture.ios`, 8 telas x claro/escuro = 16 telas, 1 app).
Script: `scripts/ios-corpus-eval.py`. Simulator: iPhone 17 Pro, iOS 26.3. OCR: Vision `accurate`, `pt-BR`+`en-US`, `ocr2.swift` do POC, no macOS.

## O que NÃO deu para medir (e por quê)

**Toda a parte de `collie device` (árvore, gatilho, latências de `ui/screen/find/tap/wait`).** Não havia painel de device
(`collie panel list` vazio; `collie device ui` responde "No device panel reachable") e este terminal não é Shepherd, então
`collie panel open device` é recusado ("a terminal that isn't a Shepherd opens only browser and preview panels").
Logo, as colunas de árvore e latência abaixo são **n/a**, não zero. O script já faz essa parte (`--panel <nome>`), mas o
parser da árvore (`tree_info`, contagem de nós) **nunca rodou contra a saída real**; o formato de `ui --all` foi
presumido e precisa ser conferido na primeira execução com painel.

Também não medido: posição do toque (critério 4; exige `tap` e comparar a tela), latência do OCR dentro do `collied`
(medi o binário do POC, não o daemon; o OCR ainda não está ligado ao iOS), `find --scroll` na lista, escala de 0,5x (`fast`).
O corpus tem 16 telas de 1 app em 1 aparelho, longe das 30 telas de 5 apps do critério 1.

## OCR (medido)

Gabarito no script (texto visível, sem barra de status). Recall com casamento aproximado (igual, contido ou razão >= 0,85).

| Tela | Árvore esperada | Nós rotulados | Itens no gabarito | Recall OCR claro / escuro | Itens OCR | OCR ms (claro / escuro) |
|---|---|---|---|---|---|---|
| normal | boa | n/a | 4 | 100% / 100% | 5 | 244 / 237 |
| canvas | pobre | n/a | 5 | 100% / 100% | 6 | 237 / 235 |
| game (SpriteKit) | pobre | n/a | 4 | 100% / 100% | 5 | 177 / 182 |
| webcanvas | pobre | n/a | 5 | 100% / 100% | 6 | 284 / 242 |
| hidden | pobre | n/a | 4 | 100% / 100% | 5 | 148 / 193 |
| photo | pobre | n/a | 4 | 100% / 100% | 5 | 297 / 315 |
| list (12 linhas visíveis) | boa | n/a | 14 | 100% / 100% | 18 | 312 / 299 |
| form | boa | n/a | 9 | 100% / 100% | 10 | 381 / 214 |

Latência do `ui`, `screen`, `find`, `tap --text`, `wait --stable`: **n/a** em todas as telas.

Resumo: pobres (n=10) recall médio 100%; boas (n=6) 100%; mediana de OCR 240 ms (mín. 148, máx. 381) por captura de 1170x2532.

Ressalvas que tiram força desses 100%:
- Corpus sintético, fonte do sistema, texto limpo e grande, pt-BR com acentos. O Android real deu 89 a 94%. Aqui o OCR
  não foi testado contra texto difícil (fontes decorativas, baixo contraste real, texto muito pequeno): só uma linha de 11 pt.
- "Precisão" 100% é frouxa: conta como real o que casa com o gabarito, a hora da barra de status e qualquer item no topo.
  Na `list` há 4 itens a mais (linhas parcialmente visíveis atrás da barra de abas) que o casamento aproximado aceitou
  como "Produto 0xx". Não use esse número como critério 3.
- A 1ª rodada tinha `list` com 93%: era erro do meu gabarito ("Produtos" não aparece; a aba mostra "Catálogo").
  Corrigi o gabarito, não o OCR.
- O tempo é a mediana de 3 execuções aquecidas no processo do POC (a 1ª, fria, é descartada), em máquina sem outra carga.

## Comparação com os critérios do Android

| # | Critério | Meta | Resultado iOS |
|---|---|---|---|
| 1 | Gatilho | >=90% pobres, <5% boas, corpus >=30 telas de >=5 apps | **não medido** (sem árvore); corpus de 16 telas / 1 app |
| 2 | Recall de texto | >=90% `accurate` | 100% nas 16 telas, corpus sintético; `fast` não medido |
| 3 | Precisão | >=90% | **não medido de forma válida** (ver ressalva) |
| 4 | Posição | >=95% | **não medido** |
| 5 | Latência | OCR <=250 ms `accurate`; `screen` <=500 ms | OCR mediana 240 ms, mas 6 de 16 telas passam de 250 ms (máx. 381); `screen` não medido |
| 6 | Sem regressão | árvore boa idêntica, gatilho <5 ms | não medido |
| 7 | Degradação | `ocr: unavailable` | não medido (OCR não ligado ao iOS) |
| 8 | Privacidade | nada persistido | não medido (o script grava PNG em diretório temporário do próprio script) |

Nenhum critério está declarado cumprido aqui. O único número firme é o recall de OCR do corpus sintético e a latência do POC.

## Sobre o fixture (achados úteis)

- `webcanvas` leva ~5 s para desenhar o `<canvas>` (WKWebView); o script espera 5 s. Com 2 s a tela saía em branco.
- Em `canvas`, `game` e `photo` as posições usam `top` fixo (76/100 pt): `safeAreaInsets` é 0 em `viewDidLoad`, e a 1ª versão
  deixou o HUD do jogo atrás da barra de status (o recall teria sido falso). Conferi as 16 capturas a olho: todo o texto fica visível.
- A tela `list` tem a barra de abas flutuante (iOS 26) cobrindo a linha ~13; o gabarito só conta as 12 primeiras linhas.
- `hidden` usa `accessibilityElementsHidden`; se o helper iOS ler a árvore por outro caminho que não o de acessibilidade, ela pode não ser pobre. Conferir com painel.
- O primeiro screenshot da tela `normal` mostrou "◄ Ajustes" na barra de status (veio de abrir o app a partir de Ajustes); a captura do script relança o app, mas pode reaparecer.

## Próximo passo

Com um painel de device aberto pelo Shepherd: `scripts/ios-corpus-eval.py --panel <nome> --out iosres.json`.
Isso preenche nós rotulados, recall da árvore, gatilho 1 (<3 rótulos; cobertura e classes opacas ainda não implementados no script) e as 5 latências.

## Adendo: árvore e latências medidas com painel (Shepherd, 2026-11-22)

`scripts/ios-corpus-eval.py --panel device-3 --runs 3` (iPhone 17 Pro, iOS 26.3, bundle com o daemon da onda helper/OCR; iOS não usa helper:
`axe describe-ui` por chamada). Dados brutos: `2026-11-22-ios-corpus-results.json`. As 16 telas rodaram; o parser da árvore funcionou na saída real.

| Medida | Resultado (16 telas, mediana de 3) |
|---|---|
| `ui` | mediana 432 ms (265 a 1.389 ms) |
| `screen` | mediana 420 ms (306 a 3.395 ms) |
| `find` | mediana 475 ms (360 a 942 ms, n=8) |
| `tap --text` | mediana 894 ms (754 a 1.024 ms, n=6) |
| `wait --stable` | mediana 1.006 ms (755 a 2.006 ms) |
| Recall da árvore, telas boas (n=6) | 100% (6, 28 e 13 nós) |
| Recall da árvore, telas ditas pobres (n=10) | 20%; nós 1, 5 ou 6 |
| Gatilho (< 3 nós rotulados) nas boas | **0 de 6** disparos (critério < 5%: cumprido) |
| Gatilho nas ditas pobres | 6 de 10 |

Leitura honesta do gatilho: das 10 telas rotuladas "pobres", **`game` (SpriteKit, 2 telas) tem a árvore completa** (5 nós, recall 100%): o SpriteKit expõe os rótulos
do HUD à acessibilidade, então ela não é pobre e não disparar está certo. Das 8 realmente pobres (canvas, webcanvas, hidden, photo; claro e escuro), o gatilho
disparou em 6 (**75%**, abaixo dos 90% do critério 1). Os 2 que escapam são `webcanvas`: o WKWebView expõe 6 nós (a página), mas não o texto do `<canvas>`,
então a regra "< 3 rótulos" não pega. É o caso para as regras 2 e 3 da spec (cobertura e classe opaca dominante, WKWebView/WebView), que este script não implementa.
A tela `hidden` com `accessibilityElementsHidden` ficou de fato pobre também no iOS (1 nó), diferente do Android com helper, que enxerga o que o app esconde.

Latência: o `ui` do iOS é bem mais curto aqui (432 ms) do que no app Ajustes (0,7 a 2,6 s medidos antes) porque as telas do fixture têm poucos nós; o custo do
`axe describe-ui` cresce com o tamanho da árvore. Continua uma ordem de grandeza acima do helper do Android (26 a 100 ms).

Critérios do Android, com o que agora tem número no iOS:

| # | Critério | iOS |
|---|---|---|
| 1 | Gatilho | falsos disparos 0/6 (ok); detecção nas realmente pobres 6/8 = 75% (abaixo de 90%); corpus ainda 16 telas de 1 app, fora do alvo de 30 telas de 5 apps |
| 5 | Latência da tela | `screen` mediana 420 ms (<= 500 ms), mas com OCR somaria ~160 a 360 ms mais: ~600 a 800 ms, acima da meta de 500 ms; OCR ainda não ligado ao iOS |
| 6 | Sem regressão | árvore boa não disparou (0/6); custo do gatilho não medido |
| 2, 3, 4, 7, 8 | demais | seguem não medidos no daemon (o OCR não existe no iOS) |

Próximos passos para igualar o Android: ligar o OCR ao iOS no daemon (`simctl io screenshot` + `VisionOCR` existente, que já roda no `collied`), implementar as regras 2 e 3
do gatilho (WKWebView e cobertura), e ampliar o corpus com mais apps (Safari com canvas, apps de terceiros).
