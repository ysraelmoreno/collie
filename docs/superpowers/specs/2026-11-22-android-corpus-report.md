# Relatório: corpus Android, calibração do gatilho do OCR (2026-11-22)

`scripts/android-ocr-eval.py --panel device-2 --serial emulator-5554` com `Helpers/android-device/corpus.json` (16 telas: 12 do fixture `com.collie.fixture`
em claro e escuro, mais Configurações, Configurações › Display, launcher e uma página no Chrome). Emulador API 37, helper v3, daemon instalado (OCR e gatilho
por rótulos, cobertura e classe opaca). Dados: `2026-11-22-android-corpus-results.json`. Todas as 16 telas estabilizaram.

## Gatilho

| Classe (como rotulei) | n | Rotulados (min / mediana / máx) | Cobertura (min / mediana / máx) | Gatilho |
|---|---|---|---|---|
| boas | 5 | 4 / 13 / 14 | 0,33 / 0,75 / 0,96 | **0 de 5** disparos (falsos disparos: 0%) |
| pobres | 11 | 0 / 0 / 5 | 0,00 / 0,00 / 0,37 | 8 de 11 |

Os 3 que não dispararam não são falha do gatilho, são erro do **meu rótulo "pobre"**: `hidden` (claro e escuro) tem 5 rotulados e cobertura 0,36, porque o helper liga
`flagIncludeNotImportantViews` e **enxerga o que o app esconde da acessibilidade**; e `chrome_canvas` tem 5 rotulados e recall de árvore 5/5, porque o Chrome expõe o texto
da página. Nas telas realmente pobres (canvas, surface, webcanvas, photo, em claro e escuro: **8 telas**) o gatilho disparou em **8 de 8**, sempre por `labels` (0 nós rotulados).

## Limites: o que o corpus diz

O script sugeriu `minLabeled = 9` e `coverageMin = 0,56` como "separadores" (com 2 erros cada). **Não adotar:** esses valores só existem porque as telas mal rotuladas entram na conta, e
elevariam os falsos disparos, já que a tela `normal` (boa, simples) tem 4 rotulados e cobertura 0,33. Com os limites atuais (menos de 3 rótulos, cobertura < 0,15) as 8 pobres
de verdade têm 0 rótulos e 0,00 de cobertura (folga enorme) e as 5 boas ficam acima (folga de 4 rótulos e 0,18 de cobertura). **Manter `minLabeled = 3` e `coverageMin = 0,15`.**
O corpus não tem nenhuma tela entre os dois grupos: a fronteira real (Compose sem semântica parcial, Flutter, jogo com HUD acessível) ainda não foi exercitada.

## OCR

| Medida | Resultado |
|---|---|
| Recall de texto | 98 de 110 (89%) no total; fixture 100%; Configurações 14/14, Display 15/16, launcher **4/15** (texto claro sobre papel de parede, o caso fraco de sempre) |
| Latência do Vision (processo do script, aquecido) | 83 a 160 ms (mediana 124) |
| `ocrMs` reportado pelo daemon nas 8 telas em que disparou | 237 a 532 ms, **mediana 322** |
| Posição certa | 57 de 73: **métrica deste script** (conta itens do OCR sem par na árvore, como relógio e bateria, como erro); não é comparável aos 99% medidos antes sobre itens casados |

O `ocrMs` do daemon (322 ms) é mais que o dobro do Vision puro (124 ms): ele inclui a captura de tela e a conversão, não só o OCR. Contra a meta "OCR ≤ 250 ms no `accurate`", o número do daemon
não cumpre; contra "`screen` ponta a ponta ≤ 500 ms" fica dentro (medido antes: 385 a 478 ms). Vale separar `captureMs` de `ocrMs` no `--timing` para a meta ficar mensurável.

## Limites desta medição
Corpus de 16 telas, 3 apps reais além do fixture, só inglês nas telas reais, emulador; os 3 apps reais têm árvore boa, então **não há app real de árvore pobre**
(o único candidato, o Chrome, expõe o texto). O gatilho foi validado só nos casos sintéticos extremos. Para uma calibração de verdade faltam apps reais com canvas, WebView opaco,
Flutter ou Unity.
