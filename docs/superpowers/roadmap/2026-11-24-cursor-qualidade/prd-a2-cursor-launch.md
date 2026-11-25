# PRD A2: `--model` e `--trust` no preset `cursor`

PRD geral: `README.md` desta pasta (problemas 3 e o diálogo de confiança).

## Problema

- `summon --model` recusa tudo que não é Claude (`ShepherdCommands.swift:97-104`: "--model is for claude"). Para usar
  Composer 2.5 o Pastor precisa de `--preset custom --command "cursor-agent --model composer-2.5"`, que é o caminho
  frágil do A1 e que um modelo fraco erra.
- O preset `cursor` lança `cursor-agent --sandbox disabled --plugin-dir …` (`AgentLaunch.swift:170-178`), sem
  `--trust`. Numa pasta nova o Cursor abre "Workspace Trust Required" e o primeiro prompt se perde.

## Fazer (`Sources/CollieDaemonKit/ShepherdCommands.swift`, `Sources/CollieDaemonKit/AgentLaunch.swift` e testes)

1. `summon --model <m>` aceito também quando o agente é Cursor (preset `cursor` ou comando `cursor-agent`). Mesma
   validação de nome (`ClaudeModel.validate`). Codex continua recusado com a mensagem de hoje.
2. Preset `cursor` com `rec.model`: acrescenta `--model <m>` (com `quote`) ao comando. Um custom que já passa `--model`
   não ganha outro.
3. `--trust` no preset `cursor` e no custom `cursor-agent` **só quando o terminal roda no sandbox do Collie**
   (`innerSandboxOff`, o mesmo critério do `--sandbox disabled`). Um custom que já passa `--trust` não ganha outro.
   Terminal livre (sem sandbox) continua mostrando o diálogo: ali confiar no repositório é decisão do usuário.
4. `docs/referencia.md`, seção Cursor: `--model` no preset, `--trust` sob sandbox.

## Decisão minha (o dono pode vetar)

`--trust` faz o Cursor aceitar o `.cursor/` do repositório (hooks e MCP do projeto) sem perguntar. Sob o sandbox do
Collie esses hooks rodam confinados como qualquer filho do terminal, e o Collie já liga o Claude sem perguntar nada
parecido. Fora do sandbox fica como está.

## Aceite

- `summon x --preset cursor --model composer-2.5`: comando com `--model 'composer-2.5'` e `--trust` (teste em
  `AgentLaunchTests`).
- Terminal livre com preset `cursor`: sem `--trust` (teste).
- `summon x --preset codex --model y`: recusado como hoje (teste em `ShepherdTests`).
- Custom `cursor-agent --model a --trust`: nenhuma flag duplicada (teste).

## Check

```
swift test --disable-sandbox --filter AgentLaunchTests && swift test --disable-sandbox --filter ShepherdTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
