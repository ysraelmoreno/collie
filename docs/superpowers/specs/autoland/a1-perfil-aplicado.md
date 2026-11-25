# A1: o `work run` aplica o bloco `factory` do perfil

Roadmap: `docs/superpowers/roadmap/2026-11-24-autoland/README.md`. Achado de 2026-11-23: o motor do laço NÃO lê `factory` do `collie-work.json`; só o `collie factory doctor` o lê.
Hoje `factory.review.*` e `factory.guardrails.*` são descrição, não regra. Reutilize o que já existe: `FactoryProfile` (`Sources/CollieCore/FactoryProfile.swift`), `ProjectWorkConfig.factory`,
e o caminho que `work run` já usa para `gate`/`precheck`/`smoke` do arquivo COMMITADO no base (`WorkConfigFile.config(base:dir:)`, `Sources/CollieDaemonKit/WorkLoopCommands.swift`, onda 13).

## O que fazer
`work run` lê `factory.review` e `factory.guardrails` do perfil do commit base, com a regra de sempre: **flag explícita vence o perfil, o perfil vence o padrão do motor**.
1. `factory.review` presente: `--review` liga por padrão. Novo `--no-review` desliga (explícito vence). As personas e o `threshold` (`blocker`|`major`) do perfil são usados pela revisão: onde o motor hoje escolhe as personas
   "auto" por caminho, a lista `factory.review.personas` (quando não vazia) restringe quais rodam; o `threshold` define a partir de qual severidade um veto falha a tentativa (hoje fixo em `blocker`/`major`: com `blocker`, só `blocker` veta).
2. `factory.guardrails.budgetSeconds` e `maxTries` viram os padrões de `--budget` e `--tries` (flag explícita vence). `factory.guardrails.destructive` e `land` são lidos e mostrados, nada mais: `destructive` ainda não bloqueia
   comando (vira aviso no `work status`), e `land` só aceita `manual` até a A4 (se vier `factory-paddock` num cercado sem a marca, o `work run` avisa e segue como `manual`).
3. `work status` mostra, para revisão, orçamento e tentativas, **de onde veio cada valor**: `perfil` ou `flag` ou `padrão` (uma linha curta por valor).
4. Perfil ausente ou sem `factory`: comportamento idêntico ao de hoje (nenhum teste antigo muda). Perfil com `factory` inválido: `work run` recusa com a mensagem do leitor estrito (uma linha), antes de iniciar o laço.

## Cuidados
- O perfil é lido do COMMIT BASE (como gate e precheck), nunca da árvore do agente; uma tentativa que edite o `collie-work.json` já cai no guard do portão.
- Não mude `ProjectWorkConfig.maxBytes`, nem o formato do arquivo, nem o `factory doctor`.
- Não aplique `destructive` como bloqueio: sem teste de comando destrutivo real aqui.

## Testes (`Tests/CollieDaemonKitTests/FactoryRunProfileTests.swift`, Swift Testing; sem `sandbox-exec` real)
Perfil sem `factory`: nada muda. Com `factory.review`: `--review` liga sem flag; `--no-review` desliga; personas do perfil restringem; `threshold: blocker` não veta `major`. Com `guardrails`: `--budget`/`--tries` herdam, e flag explícita vence.
`land: factory-paddock` sem marca: aviso e segue `manual`. `factory` inválido: recusa antes de iniciar o laço. `work status` mostra a origem. O perfil vem do commit base (a árvore suja com outro valor não vale).

Check: `scripts/check-autoland-loop.sh a1`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
