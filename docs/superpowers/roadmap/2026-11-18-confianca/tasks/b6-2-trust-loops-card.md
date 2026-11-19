# B6.2 Confiar em laços por cercado: o botão no cartão

Depende de B6.1. Código: `Sources/CollieApp/AccessViews.swift` (`AppCardView`, `answer`), `Sources/CollieClient/` (`answerApp`), `Sources/CollieDaemonKit/PaddockApps.swift` (`admin.app.answer`, por volta da linha 556-600), `Sources/CollieProtocol/Commands.swift` (`admin.app.answer`).

## Fazer

1. `admin.app.answer` ganha o parâmetro opcional `always` (bool). Só vale para um cartão `work-loop`: com `allow` e `always`, o daemon liga `trustLoops` do cercado do cartão (o mesmo efeito do `admin.paddock.trust-loops on`) e libera o laço. Para qualquer outro cartão, `always` é recusado.
2. `DaemonClient.answerApp` aceita `always`; o `AppCardView` do cartão `work-loop` mostra o botão **"Sempre neste cercado"** ao lado de Permitir, com a ajuda: "Os próximos laços deste cercado começam sem cartão; você recebe o aviso e pode parar com collie work stop. Dá para desligar nas Preferências."
3. Para desligar, um interruptor por cercado no lugar que já exista para configurações de cercado; se não houver, uma seção "Laços sem cartão" na página geral das Preferências, listando os cercados confiáveis com o botão **Revogar** (chama `admin.paddock.trust-loops off`). Sem inventar uma tela nova além dessa seção.
4. O texto do cartão do laço continua o mesmo.

## Testes (escrever antes)

`CommandsTests` e o teste do protocolo: `admin.app.answer` com `always` aparece no esquema; `MCPTests`/`CommandsTests` que enumeram comandos continuam coerentes (rode ambos). `WorkLoopCommandTests`: `always` num cartão de laço liga a confiança; `always` num cartão de app é recusado; `allow: false` com `always` não liga nada. A parte visual do app o dono confere à mão.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests`, nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar em scripts/ci/ nem em architecture-rules.txt. O app (CollieApp) só compila e é verificado à mão pelo dono: não rode o app.
