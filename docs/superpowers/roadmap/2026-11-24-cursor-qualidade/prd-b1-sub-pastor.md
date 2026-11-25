# PRD B1: sub-Pastor (`summon --shepherd`)

PRD geral: `README.md` desta pasta (problema 2). Depende do A1.

## Problema

Só o app marca um terminal como Pastor (`terminal.update` com `shepherd`, `CommandRouter.swift:788-793`). Um Pastor
convoca workers, mas nenhum deles pode delegar: `summon`, `notify`, `leash request`, `herd list` respondem
`'<cmd>' is Shepherd-only` (`ShepherdCommands.swift:10`). Na rodada 1 o Cursor convocado gastou ~3 min fazendo polling
em `collie list` e tentou um `ask` bloqueante ao Pastor que o esperava (deadlock). O dono considera delegação em
árvore uma feature importante: um Pastor forte divide o trabalho, um sub-Pastor coordena uma parte com workers baratos.

## Regras

- **Quem cria:** um Pastor, com `collie summon <nome> --shepherd`. O app continua podendo marcar qualquer um.
- **Profundidade:** no máximo 2 abaixo de um Pastor marcado pelo app (Pastor do app → sub-Pastor → sub-sub-Pastor).
  Um `--shepherd` além disso é recusado com a profundidade na mensagem.
- **Alcance:** não muda o modelo de permissão. O sub-Pastor alcança só o que está ligado a ele (os que ele convoca e
  o Pastor que o convocou). O Pastor de cima **não** alcança os netos.
- **Cercado:** o sub-Pastor fica no cercado de quem o convocou e não usa `--paddock` nem `paddock create`. Os demais
  comandos de Pastor valem para ele, inclusive `work run`, que continua exigindo o cartão do dono.
- **Teto:** um sub-Pastor tem no máximo 6 terminais vivos convocados por ele (constante; recusa com o número).
- **Dispensa:** um Pastor pode dispensar um sub-Pastor que **ele** convocou. A dispensa é em cascata: primeiro os
  convocados pelo sub-Pastor (recursivo), depois ele. Um Pastor marcado pelo app continua sem poder ser dispensado por
  agente.
- **Sandbox:** sub-Pastor só com sandbox (o mesmo `refuseFreeSummoner` de hoje).

## Fazer

1. `TerminalRecord.summonedBy: UUID?` (`Sources/CollieCore/Workspace.swift`; opcional, decodifica workspaces antigos),
   gravado no `summon` (`ShepherdCommands.swift:87`) e pelo laço (`WorkLoopCommands.swift:672`) com o id de quem
   convocou.
2. `summon --shepherd` (protocolo em `Sources/CollieProtocol/Commands.swift`, CLI e MCP): `rec.isShepherd = true`
   antes do `launch`, então o `COLLIE_SHEPHERD` e a orientação de Pastor saem na primeira sessão.
3. Profundidade = número de ancestrais por `summonedBy` até um Pastor sem `summonedBy`. Recusas: profundidade,
   `--paddock`, `paddock create` por sub-Pastor, teto de 6.
4. `dismiss` (`ShepherdCommands.swift:23-25`): aceita Pastor quando `t.summonedBy == me.id`; cascata pelos
   `summonedBy`.
5. Mensagem de recusa para quem não é Pastor (`ShepherdCommands.swift:10`), para `summon`: acrescentar
   `peça a quem te convocou (collie ask <nome> --no-wait) ou ao usuário para te marcar como Pastor no app`.
6. Orientação de um sub-Pastor (`CollieOrientation`): uma linha a mais, dentro do limite de 1500, com o nome do Pastor
   de cima e "responda a ele com collie reply / lot post; não espere por ele com ask bloqueante".
7. `docs/referencia.md`: seção do Pastor, as regras acima.

## Aceite (em `ShepherdTests`)

- Pastor convoca `sub --shepherd`; `sub` convoca `w1`; `sub` alcança `w1`, o Pastor não.
- Terceiro nível passa, quarto é recusado.
- Sub-Pastor com `--paddock` ou `paddock create`: recusado.
- Sétimo terminal vivo de um sub-Pastor: recusado.
- Pastor dispensa `sub`: `w1` some antes; Pastor não dispensa um sub-Pastor convocado por outro.
- Workspace salvo sem `summonedBy` carrega.
- Orientação do sub-Pastor dentro do limite (`CollieOrientationTests`).

## Check

```
swift test --disable-sandbox --filter ShepherdTests && swift test --disable-sandbox --filter CollieOrientationTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
