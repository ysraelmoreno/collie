# PRD A5: aviso de resposta não repetido depois de `ask result`

PRD geral: `README.md` desta pasta (problema 7).

## Problema

`ask --no-wait` digita `[collie] Reply from …` no asker quando a resposta chega (`CommandRouter.askNoWait`,
`CommandRouter.swift:570-571`, com `afterQuiet: true` e `hold` de 30 min). Se o asker já leu a resposta com
`collie ask result <id>` antes de ficar quieto, o aviso chega mesmo assim. Em 2026-11-24 chegaram três avisos assim,
cada um um turno inteiro do Pastor sem nada novo.

## Fazer (`Sources/CollieDaemonKit/AskInbox.swift`, `Sources/CollieDaemonKit/CommandRouter.swift` e testes)

1. `AskInbox.Entry` ganha `readAt: Date?` (opcional, decodifica arquivos antigos). `ask.result <id>` de uma entrada
   `done`/`failed` marca `readAt` (a lista sem id não marca).
2. O aviso não é digitado se a entrada já tem `readAt` no momento da escrita: a checagem vale na hora de escrever, não
   só na de enfileirar (o aviso espera o asker ficar quieto, e é nesse intervalo que ele lê). Usar o caminho de
   `inject` com uma condição avaliada na escrita, ou cancelar o inject pendente quando `readAt` é marcado.
3. `AskInbox.json` mostra `readAt`.

## Aceite

- Resposta chega, asker chama `ask result` antes de ficar quieto: nenhum aviso digitado (teste com relógio falso).
- Resposta chega, asker não lê: aviso digitado como hoje (teste).
- Arquivo de inbox sem `readAt` carrega (teste).

## Check

```
swift test --disable-sandbox --filter AskTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
