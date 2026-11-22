# Brief: apps iOS de teste para o corpus de `collie device` (fixtures)

Você é um agente delegado pelo Shepherd do Collie. Crie alguns apps iOS pequenos para o Simulator, com telas de acessibilidade boa e pobre, para medir `collie device screen|ui|find|tap|wait` e o OCR no iOS. Equivalente ao fixture Android `Helpers/android-device/fixture/` (leia-o e `docs/superpowers/specs/2026-11-22-device-ocr-fallback-design.md`, seção de critérios, para o nível de qualidade pedido).

## Limites (importante)
- NÃO instale nem reinicie o Collie, NÃO rode `scripts/bundle-app.sh`, NÃO faça push, NÃO crie paddocks nem terminais. Não rode a suíte completa de testes.
- Pode compilar os apps e instalar no Simulator já ligado (iPhone 17 Pro, `08A7691B-D06D-4FA3-ACA4-CA260E75DFB1`) com `xcrun simctl install`. Use `collie device ...` para conferir (`--panel <nome>`; veja `collie panel list`).
- Faça commits só dos seus arquivos (git add por caminho), com o trailer Co-Authored-By no fim da mensagem. Não mexa em arquivos rastreados fora de `Helpers/ios-device/`, `docs/` e `scripts/` (só os novos).
- Sem Xcode project grande: prefira `swiftc -sdk $(xcrun --sdk iphonesimulator --show-sdk-path) -target arm64-apple-ios17.0-simulator` mais um `Info.plist` e um script que monta o `.app`, assina ad-hoc e instala. Um único app com uma tela por argumento de launch (`xcrun simctl launch <udid> <bundle> --screen canvas --dark`), como no Android, é melhor que vários projetos.

## O que construir (`Helpers/ios-device/fixture/`)
Bundle `com.collie.fixture.ios`, nome "Collie OCR Fixture". Telas selecionadas por `--screen <nome>` e, opcionalmente, `--dark`:
1. `normal`: controle, UIKit/SwiftUI comum com acessibilidade boa (título, texto, botão, rodapé). Arvore boa: o OCR não pode disparar.
2. `canvas`: texto e botões DESENHADOS com Core Graphics numa UIView sem elementos de acessibilidade; um botão "+" só com ícone desenhado.
3. `game`: SpriteKit (ou Metal) com HUD de jogo (SCORE, Vidas, JOGAR, Nível).
4. `webcanvas`: WKWebView com texto dentro de `<canvas>` (JavaScript ligado).
5. `hidden`: views comuns com `accessibilityElementsHidden = true`.
6. `photo`: texto claro sobre fundo tipo foto (gradiente e ruído).
7. `list`: lista rolável longa (80 itens "Produto 001..080", pt-BR) para testar `find --scroll`, mais uma barra de abas (2 abas) e um campo de busca.
8. `form`: campos de texto, switch, picker, botão, alerta e sheet.
Texto em pt-BR com acentos, números e `R$ 1.234,56`, uma linha em fonte pequena, e cada tela em claro e escuro. A altura útil da tela é menor que a do dispositivo (barra de status e área segura): confira que todo o texto fica visível, senão a medição de recall fica falsa.

## Medição (entregue como script e relatório)
`scripts/ios-corpus-eval.py` (ou `.sh`): para cada tela e tema, abre o app, espera a tela ESTÁVEL (duas leituras da árvore iguais; descarte o que não estabiliza), captura `collie device screenshot` e `collie device ui --all`, e compara com o texto conhecido de cada tela (gabarito no próprio script): recall de texto pela árvore e latência de `ui`, `screen`, `find`, `tap --text`, `wait --stable` (mediana de 5). Rode os OCR do macOS (Vision) sobre o screenshot, com o binário/script de `docs/superpowers/specs/2026-11-22-device-poc/ocr/` (ocr2.swift), para ter o recall do OCR nas telas pobres (o OCR ainda não está ligado ao iOS no daemon).
Relatório em `docs/superpowers/specs/2026-11-22-ios-corpus-report.md`: tabela por tela (nós rotulados, recall da árvore, recall do OCR, latências), e a comparação com os critérios do Android (gatilho em >=90% das pobres e <5% das boas; recall >=90% accurate; posição >=95%; latência). Diga o que NÃO deu para medir e por quê (honestidade antes de número bonito).

## Entrega
Commits pequenos (fixture, script, relatório). Ao final responda curto: o que foi feito, os números principais e o que falhou. Não declare critério cumprido sem o número medido.
