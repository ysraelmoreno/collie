# PRD D1: hooks de ferramenta do Cursor → contrato de plug-in

PRD geral: `README.md` desta pasta (problema 8). Depende do A1. Contrato:
`docs/superpowers/roadmap/2026-11-20-ganchos-plugin/README.md` (eventos `edit` e `stop`, veredito `guide`/`block`).

## Problema

O PRD dos ganchos deixou o Cursor de fora: "o gancho de edição do Cursor não foi verificado". Em 2026-11-24, com
`cursor-agent` 2026.11.22-e9042b2 e um plug-in sonda por `--plugin-dir`, dispararam no interativo `preToolUse`,
`postToolUse`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterAgentThought` (com
`tool_name` como `Read`, `MCP:memory_search`), e no `-p` também `beforeShellExecution`, `afterShellExecution`,
`sessionEnd`. Não dispararam `stop`, `afterAgentResponse`, `beforeSubmitPrompt`. O plug-in do Collie para o Cursor
(`AgentLaunch.cursorPlugin`, `AgentLaunch.swift:56-67`) registra só `sessionStart`.

## Fazer

1. **Medir o que falta** e anotar no spike (`docs/superpowers/spikes/2026-10-22-cursor/REPORT.md`, seção nova com a
   versão): o payload do `postToolUse` para uma escrita (nome da ferramenta e onde vem o caminho), se `afterFileEdit`
   dispara, e o formato de resposta que o Cursor aceita em `preToolUse` (negar com motivo ao agente) e em
   `postToolUse` (contexto extra). O que não for aceito vira "não suportado" neste PRD, sem gambiarra.
2. `cursorPlugin` registra `preToolUse` e `postToolUse` com um subcomando novo `collie hook cursor-tool`
   (`Sources/collie/HookCommands.swift`, `AgentLaunch.hookSubcommands`).
3. `cursor-tool` manda o evento ao daemon, que:
   - marca o terminal como em turno (atualiza o mesmo estado que o badge `working` lê), para o idle do ask não fechar
     no meio de uma ferramenta longa;
   - numa escrita (`postToolUse` de escrita), monta o evento `edit` do contrato (`PluginHooks`, `agent: "cursor"`) e
     devolve o veredito no formato que o passo 1 mediu. `block` em `postToolUse` sem suporte do Cursor vira `guide`.
4. **`stop` do Cursor:** o daemon gera o evento `stop` quando o turno termina por ociosidade (`AskCoordinator.pollIdle`
   ou o fim de turno do badge), com os arquivos escritos no turno. Como o turno já acabou, um `block` vira **um** prompt
   de continuação (`inject`, com o texto do plug-in), uma vez por turno; `guide` é ignorado, como no Claude.
5. `docs/referencia.md`, seção Cursor: o que dispara e o que o Collie faz com cada um.

## Aceite

- `AgentLaunchTests`: o `hooks.json` do plug-in Cursor tem `sessionStart`, `preToolUse`, `postToolUse`.
- Payload de escrita gravado no passo 1 como fixture: vira `edit` com o caminho relativo certo (teste puro).
- Veredito `block` de um plug-in no fim de turno do Cursor: exatamente um prompt de continuação (teste).
- Ask a um Cursor com ferramenta rodando há mais que `idleQuiet` sem saída na tela: não fecha por ociosidade (teste).

## Check

```
swift test --disable-sandbox --filter AgentLaunchTests && swift test --disable-sandbox --filter PluginHooksTests \
  && swift test --disable-sandbox --filter AskTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
