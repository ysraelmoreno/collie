# PRD G5: os ganchos do Claude imprimem a resposta do plug-in

PRD geral: `README.md` desta pasta. Depende de G2 (`PluginHooks`); usa o comando `plugin.hook` de G4 pelo nome e
pela forma da resposta (`{guide?, block?}`), sem depender do código dele.

## Problema

`collie hook claude-tool` hoje só repassa o evento ao registro de trabalho e não imprime nada.
`collie hook claude-stop` só bloqueia para o pedido de memória. O veredito dos plug-ins não tem por onde chegar
ao agente.

## Fazer

Arquivos: `Sources/collie/HookCommands.swift`; `Sources/CollieDaemonKit/MemoryHookClient.swift` (ou um
`PluginHookClient.swift` novo ao lado, no mesmo estilo testável); `Sources/CollieDaemonKit/AgentLaunch.swift`
(só o prazo do gancho); testes em `Tests/CollieDaemonKitTests/PluginHookClientTests.swift`.

1. `claude-tool`: depois do `work.hook` (que continua igual), chamar `plugin.hook` com `event: "edit"` e o mesmo
   payload, prazo de 4 s. Havendo veredito, imprimir `PluginHooks.claudeToolOutput`. Os outros subcomandos do
   mesmo `case` (`claude-subagent-stop` etc.) não chamam `plugin.hook`.
2. `claude-stop`: chamar `plugin.hook` com `event: "stop"`. Se houver `block`, o bloqueio impresso é o do plug-in;
   se também houver o pedido de memória (`ask`), os dois textos vão no mesmo bloqueio, o do plug-in primeiro.
   Um Stop continuado nunca bloqueia (regra atual, mantida).
3. Fail open em tudo: daemon fora, prazo, erro, resposta malformada → nada impresso, uma linha em `hooks.log`.
   O `work.hook` nunca deixa de ser enviado por causa do `plugin.hook`.
4. Prazos em `AgentLaunch`: `PostToolUse` de 5 para 8 s; `Stop` de 10 para 12 s. Atualizar os testes de
   `AgentLaunchTests` que fixam esses números.
5. A lógica fica numa função testável sem processo (recebe stdin e env, devolve a string a imprimir), como
   `MemoryHookClient.stopOutput`.

## Aceite

`PluginHookClientTests`, com um daemon falso no socket (o padrão que `MemoryHookTests` já usa):

- `edit` com `guide` → JSON de `additionalContext`;
- `edit` com `block` → JSON de `decision: block`;
- `edit` sem veredito → nada;
- `stop` com `block` → bloqueio; `stop` com `block` e `ask` → um bloqueio com os dois textos;
- `stop` continuado → nada, mesmo com `block`;
- daemon que não responde → nada, dentro do prazo;
- `work.hook` enviado mesmo quando `plugin.hook` falha.

## Check

```
swift test --disable-sandbox --filter 'PluginHookClientTests|AgentLaunchTests'
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
