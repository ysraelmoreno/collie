# A2: a marca "cercado fábrica"

Roadmap: `docs/superpowers/roadmap/2026-11-24-autoland/README.md`. Decisão do dono de 2026-11-22 (seção F4 de `docs/superpowers/roadmap/2026-11-22-fabrica/README.md`): marca persistente no cercado, que **só o dono liga**; o agente não consegue.
Esta tarefa é daemon e CLI (a UI é a A3). Siga como os outros campos de cercado são guardados (modelo do cercado em `Sources/CollieCore`, ver `PaddockModelTests`; e como `paddock create`, `paddock list` e `paddock status` leem e gravam).

## O que fazer
1. Campo persistente `factory: Bool` (padrão `false`) no cercado; cercados antigos, sem o campo, valem `false` (decodificação tolerante; nada migra).
2. `paddock create --factory` (cria já marcado) e `paddock factory <nome> on|off`. Ambos são comandos de **admin**: valem só vindos do app Collie ou da CLI do dono, **nunca por MCP** (`exposedToMCP: false`) **nem por terminal de agente**. Siga exatamente o
   padrão dos comandos `admin.*` existentes para o principal (um terminal de agente recebe erro de permissão, e há teste disso).
3. `paddock list` e `paddock status` incluem `factory` (booleano); o texto humano mostra "fábrica" ao lado do nome.
4. **Ligar exige perfil válido:** `paddock factory <nome> on` lê o `collie-work.json` do cercado e roda o núcleo do doctor (`FactoryDoctor.score`, só leitura); recusa se `static` ou `judge` estiver abaixo de 1 ou se o perfil for inválido,
   com uma linha dizendo qual camada e a próxima ação. Desligar nunca recusa.
5. `factory doctor` mostra uma linha "cercado fábrica: sim/não" e avisa quando `guardrails.land = factory-paddock` num cercado sem a marca (ou o cercado não é reconhecido: então só avisa, sem erro).
6. A marca não muda o comportamento do laço ainda (a A4 vai usá-la). Não implemente `--auto-land` aqui.

## Testes (`Tests/CollieDaemonKitTests/PaddockFactoryTests.swift`, Swift Testing; sem `sandbox-exec` real)
Campo ausente decodifica como `false`; `create --factory` e `factory on|off` mudam e persistem; `list` e `status` mostram; **um terminal de agente e o MCP não conseguem ligar nem desligar** (erro de permissão, marca intacta); ligar com perfil ausente ou
com `static` zerado recusa com a camada certa; ligar com o perfil do Collie (use um perfil de fixture parecido com o `collie-work.json` do repositório) passa; o doctor mostra a linha e o aviso. A marca sobrevive a reiniciar o store.

Check: `scripts/check-autoland-loop.sh a2`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
