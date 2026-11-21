# Estado do laço, Onda 13: convenção de check por projeto e painel de app que não fica em branco

Pedido do dono (2026-11-21), itens 2 e 3 da fila do Quadro: (2) a convenção genérica de check por projeto e (3) o painel de app em branco na primeira abertura. Origem do 2: a avaliação da suíte (`aval-suite-report.md`, P6/P7) e a pergunta do dono "o `laco-check.sh` é só do Collie ou de todos os daemons?" (é só do Collie: um script do repositório que o `--check` chama; o motor não conhece nada de "área" nem de "fumaça").

| # | Tarefa | Escopo | Depende de |
|---|---|---|---|
| M13.1 | `collie-work.json` do projeto: leitor estrito e `collie work config` | `Sources/CollieCore/ProjectWorkConfig.swift`, `Sources/CollieDaemonKit/WorkConfigCommands.swift`, `Sources/CollieProtocol/Commands.swift`, testes novos | |
| M13.2 | `--area` em `work task add` e padrões de `--gate`/`--precheck` vindos do arquivo | `Sources/CollieDaemonKit/WorkCommands.swift`, `WorkLoopCommands.swift`, `Work/WorkLoop.swift`, `Commands.swift`, testes | M13.1 |
| M13.3 | O laço não deixa a tentativa mexer no `collie-work.json` e lê o arquivo da base, não da árvore | `Sources/CollieDaemonKit/Work/WorkLoop.swift`, `AttemptMachine.swift`, testes | M13.2 |
| M13.4 | Painel de app em branco logo depois do `attach`: reproduzir, achar a causa e corrigir | `Sources/ColliePlugins/WebPluginPanel.swift`, `Tests/ColliePluginsTests/AppPanelBlankTests.swift` (novo), `WebPluginPanelTests.swift` | |

Check de cada tarefa: `scripts/check-onda13.sh <m13-1..m13-4>`. A M13.4 é independente (outro alvo) e roda em paralelo com a cadeia M13.1 → M13.3.

## A convenção (`collie-work.json`, na raiz do projeto, versionado)
O que o Collie sabe de um projeto para o laço, sem o motor conhecer o projeto. Todos os campos são opcionais:
```json
{ "version": 1,
  "gate": "scripts/ci/lint.sh && scripts/ci/check-architecture.sh",
  "precheck": "swift build --build-tests",
  "smoke": "scripts/laco-check.sh --smoke",
  "areas": { "ask": "swift test --filter AskTests", "quadro": "scripts/check-onda12.sh q12-1" },
  "full": "scripts/laco-check.sh --full" }
```
- `gate` e `precheck`: padrão de `--gate` e `--precheck` de `work run` quando a flag não vem (a flag sempre vence).
- `areas`: nome (`a-z0-9-`, até 40 caracteres, até 50 áreas) → comando. `collie work task add --area ask,quadro` monta o `--check` da tarefa como `<comando da área 1> && <comando da área 2> && <smoke>`. Uma tarefa com `--check` explícito e `--area` juntos é erro.
- `smoke`: comando que entra em todo check montado por área. `full`: o portão final que o **Pastor** roda no fim da onda (o motor só mostra; não roda sozinho).
- Limites e segurança: arquivo ≤ 16 KB, JSON estrito (chave desconhecida é ignorada e listada como aviso em `work config`, tipo errado é erro, `version` ≠ 1 é erro), cada comando ≤ 1000 caracteres, sem caractere de controle, sem NUL. **Ler o arquivo nunca executa nada.** O arquivo é conteúdo do repositório (um agente pode escrevê-lo): por isso o laço lê a versão da **base da tarefa** (`git show <base>:collie-work.json`), nunca a da árvore de trabalho, e uma tentativa que altera o arquivo reprova (M13.3).
- `collie work config`: mostra o arquivo efetivo (de onde veio: base `<sha curto>` ou árvore, quando não há laço), os avisos e os comandos que cada área vira. Só leitura.

## Regras de todas as tarefas
As de `README.md` desta pasta e de `onda11.md` (repositório público; sem `sleep` nem relógio de parede em teste; nenhum arquivo novo fora do pedido; só `--filter` das suítes que mexeu). O comportamento de quem **não** tem `collie-work.json` não muda em nada: mesmos padrões, mesmas mensagens, mesmos testes (`WorkCommandTests`, `WorkLoopTests` seguem verdes sem adaptação, salvo o que a tarefa pede).
