# PRD G2: tipos puros do contrato de gancho

PRD geral: `README.md` desta pasta (seção "Contrato").

## Problema

O executor (G4) e os ganchos do Claude (G5) precisam concordar sobre o evento, a resposta e a saída que o Claude
Code entende. Isso é lógica pura e deve existir, testada, antes de qualquer processo rodar.

## Fazer (arquivo novo `Sources/CollieDaemonKit/Plugins/PluginHooks.swift` e
`Tests/CollieDaemonKitTests/PluginHooksTests.swift`; nenhum outro arquivo)

Um `enum PluginHooks` público com funções puras:

1. `editedFiles(toolPayload: Data, project: URL) -> [String]`: do JSON do `PostToolUse` do Claude Code, os arquivos
   escritos pelas ferramentas `Write`, `Edit`, `MultiEdit`, `NotebookEdit` (`tool_input.file_path` ou
   `notebook_path`), relativos a `project`. Fora do projeto, outra ferramenta, JSON inválido ou acima de 64 KiB:
   lista vazia. Resolver `..` antes de comparar.
2. `eventJSON(event:project:files:agent:paddock:) -> Data`: o JSON do stdin do helper, chaves ordenadas.
3. `struct Verdict { guide: String?; block: String? }` e `verdict(stdout: Data) -> Verdict?`: `nil` para vazio,
   `{}`, JSON inválido, tipos errados ou stdout acima de 64 KiB. Texto cortado em 2000 caracteres; só espaços = nil.
4. `merge(_ verdicts: [(plugin: String, Verdict)], event:) -> Verdict`: junta na ordem do id do plug-in, cada
   trecho prefixado com `[plug-in <id>] `, total cortado em 4000 caracteres. Em `stop`, `guide` é descartado.
   Em `edit`, havendo algum `block`, o resultado é `block` (os `guide` entram depois, no mesmo texto).
5. `claudeToolOutput(_ v: Verdict) -> String?`: o JSON do stdout do `PostToolUse`: `guide` vira
   `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":…}}`; `block` vira
   `{"decision":"block","reason":…}`. Veredito vazio: `nil`.
6. `claudeStopReason(_ v: Verdict) -> String?`: o texto do bloqueio de `stop` (o chamador já tem
   `HookPayload.claudeStopBlock(reason:)`).

O texto do plug-in é dado, não instrução do Collie: nenhuma função acrescenta frases próprias além do prefixo.

## Aceite

`PluginHooksTests` cobre cada função, incluindo: caminho fora do projeto; `../` que sai do projeto; `MultiEdit`;
stdout com lixo; corte em 2000 e 4000; `stop` descarta `guide`; ordem estável por id; saída JSON decodificável.

## Check

```
swift test --disable-sandbox --filter PluginHooksTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
