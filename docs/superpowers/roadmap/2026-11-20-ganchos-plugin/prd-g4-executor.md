# PRD G4: executor no daemon e comando `plugin.hook`

PRD geral: `README.md` desta pasta. Depende de G1 (manifesto), G2 (`PluginHooks`), G3 (`PluginHelperProfile`).

## Problema

Nada no daemon entrega eventos de agente a plug-ins. Falta rodar o helper de cada plug-in que declarou o evento,
no sandbox, dentro do prazo, e devolver um veredito único.

## Fazer

Arquivos: novo `Sources/CollieDaemonKit/Plugins/PluginHookRunner.swift`; `Sources/CollieProtocol/Commands.swift`
(o comando); `Sources/CollieDaemonKit/CommandRouter.swift` (a rota); novo
`Tests/CollieDaemonKitTests/PluginHookRunnerTests.swift`.

1. `PluginHookRunner.run(event:files:project:agent:paddock:plugins:dataRoot:) async -> PluginHooks.Verdict`:
   - `plugins`: os carregados e habilitados de `PluginStore.loaded()` cujo manifesto declara o evento;
   - para cada um, em paralelo: `BoundedProcess.run` de `PluginHelperProfile.command(…)`, com o evento
     (`PluginHooks.eventJSON`) no stdin, `cwd` na pasta do plug-in, env mínimo (`PATH=/usr/bin:/bin`, `HOME` na
     pasta de dados, `COLLIE_PLUGIN_DATA`), saída limitada a 64 KiB;
   - pasta de dados `<dataRoot>/<id>/`, criada 0700 na primeira vez;
   - prazo: 3 s para o conjunto; o que não respondeu é morto e ignorado;
   - exit ≠ 0, estouro ou JSON inválido: ignorado, uma linha no log do daemon com o id e o motivo (sem o stdout);
   - resultado: `PluginHooks.merge`.
   - sem plug-in para o evento, ou `files` vazio em `edit`: devolve veredito vazio sem iniciar processo.
2. Comando `plugin.hook` (só de terminal, nunca admin; sempre `ok`, como `work.hook`):
   args `event` (`edit`|`stop`) e `payload` (o JSON bruto do gancho do Claude, ≤ 64 KiB).
   - `edit`: `files` = `PluginHooks.editedFiles(payload, project)`; soma os arquivos ao conjunto "escritos neste
     turno" do terminal (em memória, no máximo 200);
   - `stop`: `files` = o conjunto do turno, que é zerado; um Stop continuado (`stop_hook_active` verdadeiro) não
     roda plug-ins e devolve vazio;
   - `project`: a raiz do worktree do cercado do terminal (ou o `cwd` do terminal fora de cercado);
   - resposta: `{guide?: String, block?: String}`.
3. O turno também é zerado quando o terminal é dispensado.
4. Um helper nunca recebe evento de um terminal que não é de agente Claude (não-objetivo do PRD geral).

## Aceite

`PluginHookRunnerTests`, com plug-ins de teste cujo helper é um script `sh` instalado num `PluginStore` temporário:

- helper que responde `guide` → veredito com o prefixo do plug-in;
- dois plug-ins → ordem por id;
- helper que dorme 10 s → resposta em menos de 4 s, veredito vazio, o processo não sobrevive;
- helper com exit 1 e helper que imprime lixo → vazio;
- plug-in desabilitado ou sem o evento declarado → não roda (o script deixaria um arquivo marcador);
- `edit` com arquivo fora do projeto → não roda;
- `stop` devolve os arquivos do turno uma vez e zera;
- `stop` continuado → vazio;
- o helper não consegue escrever no projeto (marcador ausente).

Se `sandbox-exec` não estiver disponível no ambiente de teste, seguir o mesmo critério de pular de G3.

## Check

```
swift test --disable-sandbox --filter PluginHookRunnerTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Sem `Task.sleep`/`try!`/`@unchecked Sendable` novos (a catraca de `scripts/ci/lint.sh` recusa). Commit com
mensagem convencional, só dos seus arquivos; nada de push.
