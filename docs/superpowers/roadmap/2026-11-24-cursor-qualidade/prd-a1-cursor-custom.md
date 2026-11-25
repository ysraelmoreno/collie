# PRD A1: um Cursor por comando custom é Cursor em todo lugar

PRD geral: `README.md` desta pasta (problema 3).

## Problema

Para escolher o modelo do Cursor hoje é preciso `--preset custom --command "cursor-agent --model …"`. Esse terminal
é Cursor para a orientação (`MemoryCommands.agentName`, `MemoryCommands.swift:761`) e para o idle
(`AskCoordinator.swift:412`, `cursorTUI`), mas é "outro" em vários pontos que testam só o preset:

| Onde | O que perde |
|---|---|
| `AttentionDetector.swift:37` (`init(preset:)`) | cartão das permissões, da tela de login e do "Workspace Trust Required" |
| `AskCoordinator.swift:441` (`replyHint`) | a linha "responda com collie reply" no prompt de um ask entre agentes |
| `CommandRouter.swift:562` (`askNoWait`, `typed`) | o aviso `[collie] Reply from …` digitado no asker |
| `CommandRouter.swift:625` (fim de turno ao Pastor) | o aviso de fim de turno quando o Pastor é um Cursor custom |
| `LeashRequestCommands.swift:39` | o aviso de guia aceita/recusada |
| `PaddockApps.swift:620`, `:740` | avisos de apps do cercado |

O mesmo vale para um Claude custom (`claude --…`) nos pontos que listam `[.claude, .codex, .cursor]`. Observado em
2026-11-24: o terminal custom ficou parado no diálogo de confiança, sem cartão.

## Fazer

1. Uma função única que diz o agente de um `TerminalRecord`: reusar `MemoryCommands.agentName(_:)` (move-la para um
   lugar comum se o lint de arquitetura pedir; não criar uma segunda).
2. `AttentionDetector.init` recebe o nome do agente (`"claude"|"cursor"|"codex"|"other"`) em vez do `Preset`; o chamador
   (`AttentionDetector.swift:92`, `:102` e quem constrói o `Fanout`) passa `agentName(rec)`. Os padrões do Claude
   continuam só para Claude.
3. `AskCoordinator.swift:441`: `replyHint` quando o alvo é Cursor por `agentName` (o `Target` já guarda `cursorTUI`;
   usar esse campo).
4. Os pontos com `[.claude, .codex, .cursor].contains(preset)` passam a usar `agentName(rec) != "other"`.

Não mudar comportamento de shell nem de um custom que não é agente.

## Aceite

- Terminal `custom` com `cursor-agent --model composer-2.5`: o diálogo de confiança e um "Run this command?" viram
  atenção (teste no `AttentionDetector` com o texto capturado: `Workspace Trust Required` / `[a] Trust this workspace`).
- Ask entre agentes para um Cursor custom leva a linha do `replyHint` (teste em `AskTests`).
- Ask `--no-wait` vindo de um Cursor custom digita o aviso de resposta nele (teste).
- Shell e custom não-agente: nada muda (teste).

## Check

```
swift test --disable-sandbox --filter AskTests && swift test --disable-sandbox --filter AttentionTests
```


---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
