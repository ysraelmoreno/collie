# T6 Compacta: voltar ao canvas das Preferências

Leia primeiro o `README.md` desta pasta. Depende de T4 e T5.

Código: `Sources/CollieApp/Shell.swift` (`CanvasChrome`, `CompactBar`), `Sources/CollieApp/CollieApp.swift` (onde `CanvasChrome` é montado), `Tests/CollieAppTests/ShellTests.swift`.

A estrutura Compacta não tem faixa de abas (a barra flutua sobre o canvas). Como as Preferências agora substituem o canvas nas duas estruturas, a Compacta precisa de um jeito visível de voltar.

## Fazer

1. Na estrutura Compacta, com `mainView == .preferences`, a barra flutuante (`CompactBar`) troca o campo de busca por um botão **← Canvas** (e o título "Preferências"); o resto da barra (marca, chips de cercados, uso) continua. Em Completa nada muda (a aba Canvas já volta).
2. Passe `mainView` e a ação de voltar para `CanvasChrome`/`CompactBar` por parâmetro (sem estado global); o zoom flutuante some enquanto as Preferências estão abertas (zoom do canvas escondido não faz sentido).
3. Os banners (cartões, erros, serviço desatualizado) continuam aparecendo por cima das Preferências na Compacta e na Completa: um cartão de acesso nunca fica escondido atrás das Preferências.
4. Garanta que alternar Compacta ↔ Completa com as Preferências abertas mantém a aba e não refaz o canvas.

## Testes (escrever antes)

Em `ShellTests`: com `mainView == .preferences`, alternar a estrutura entre `.compact` e `.full` várias vezes mantém `counter.made == 1` e `dismantled == 0`; e uma função pura que decide o que a barra Compacta mostra (`showsBack`, `showsZoom`, `showsCommandField` para cada `mainView`) com os valores esperados.
