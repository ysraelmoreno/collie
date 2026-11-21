# M5.6 Modelo padrão dos agentes do laço e orientação de espera

Leia `onda5-economia-de-tokens.md`. Código: `WorkLoopCommands.swift` (`work.run`, `--model`, `--preset`), `Sources/CollieCore` (onde ficam as preferências do daemon, procure como `trustLoops` é guardado por cercado), `Sources/CollieApp/PreferencesView.swift` e a página Laços (B6.3), `CollieOrientation.swift`.

## Fazer
1. Preferência do daemon `loopModel` (opcional, vazio = como hoje: o modelo do Pastor). Quando preenchida, `work run` sem `--model` usa-a; `--model` explícito sempre vence. Validação: só caracteres de id de modelo (`[A-Za-z0-9._:-]{1,64}`), recusa o resto.
2. Comando admin (`admin.loop-model`) e leitura em `work status` (`modelo dos agentes: <x>`); a página Laços das Preferências ganha o campo (UI mínima, só nesta página).
3. Orientação do Pastor e `/collie:loop` (1500 caracteres): "uma espera longa (`work wait --timeout 3600`) vale mais que várias curtas; não responda aviso de laço com texto, leia o estado só quando precisar".

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopModelDefaultTests.swift`
Sem preferência ⇒ modelo do Pastor (como hoje); com preferência ⇒ usa; `--model` vence; valor inválido recusado; `work status` mostra; orientação dentro do limite. Os testes de `work.run` seguem verdes.
