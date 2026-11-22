# M5.3 Limite de uso do modelo para o laço na hora

Leia `onda5-economia-de-tokens.md`. Código: `Sources/CollieDaemonKit/AskCoordinator.swift` e o que lê a tela do terminal do agente (veja como o daemon reconhece diálogos de aprovação/pergunta), `Work/WorkLoop.swift` e `AttemptMachine.swift` (efeitos e eventos), `Sources/CollieCore/Work.swift` (`Stop.Code`), `WorkStatusText.swift`.

## Problema
Quando o limite de uso do modelo é atingido, o agente do laço fica no diálogo de limite ("You've hit your … limit · resets …"): o turno só termina no timeout (1 h) e as tentativas seguintes falham com `did not submit`. Perdidas 2 h e 3 tentativas em 2026-11-20.

## Fazer
1. Reconhecer o diálogo de limite na tela do agente da tentativa (texto de limite de uso e o menu "Stop and wait for limit to reset"), **só** quando o agente está parado no diálogo (sem saída recente). Não digitar nada nele.
2. Novo evento da `AttemptMachine` (`usageLimit`), novo `Stop.Code.usageLimit` (decodificação tolerante) e nota clara: `o agente atingiu o limite de uso do modelo (<texto curto>); relance com work run --model <outro>`. A tentativa **não conta** (devolve `used`), o terminal é dispensado, **nada é descartado** (como a M2.2b) e o laço **para** em vez de seguir tentando.
3. O texto lido da tela vira **dado**: só um trecho curto (≤ 80 caracteres) sem controle, escapado, na nota.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/UsageLimitDetectionTests.swift`
Telas falsas: com o diálogo ⇒ detecta e para com `usageLimit` e `used` devolvido; texto parecido numa saída normal do agente (ele escrevendo sobre o limite) ⇒ **não** detecta; agente imprimindo ⇒ não detecta; trecho longo/com controle é cortado/escapado; novos casos na tabela de `AttemptMachineTests`; `Stop.Code` desconhecido decodifica.
