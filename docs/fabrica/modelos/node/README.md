# Modelo de fábrica: node

- **Dono:** Ysrael Moreno (repositório Collie). Mudança no modelo passa por revisão como código.
- **Versão do modelo:** 1, de 2026-11-23.
- **Usado por:** `/collie:factory init` (`docs/fabrica/skill/factory-init/SKILL.md`), que copia daqui sem sobrescrever nada.

## O que tem

| Arquivo | Vai para | Para quê |
|---|---|---|
| `profile.json` | `collie-work.json` (mesclado) | gate, precheck, smoke, áreas e o perfil `factory` (U1) |
| `scripts/gate.sh` | `scripts/gate.sh` | o `gate` (`bash scripts/gate.sh # jest.config.js vitest.config.ts vite.config.ts`): roda o runner direto e falha se `package.json`, `jest.config.*`, `vitest.config.*`, `vite.config.*` ou `vitest.workspace.*` força sucesso (`passWithNoTests: true`, `testFailureExitCode: 0`, `--co`/`--collect-only`, `_exit(0)`, `exitstatus = 0`/`False`/`(`/`ExitCode.OK` como atribuição, fora de comentário: `#` em `.py`/`.ini`/`.toml`/`.cfg`, `//` em `.js`/`.ts`) ou é link simbólico, olhando só o que o git vê (arquivos versionados e não ignorados: nunca `venv/`, `.tox/`, `node_modules/`, `site-packages` ignorados); um link fora das configs (`CLAUDE.md -> AGENTS.md`) não conta, um link para pasta conta; o runner (`npx --no-install vitest run` ou `npx --no-install jest`) é gravado pela init, nunca escolhido pelo `package.json` em tempo de execução. O juiz protege por substring todo arquivo que o texto do gate cita: este script e as configs puras do runner depois do `#` |
| `scripts/check-feature.sh` | `scripts/check-feature.sh` | check de UMA tarefa: roda só os testes dela e falha se nenhum rodou; nunca só compila |
| `ci.yml` | `.github/workflows/ci.yml` | esqueleto de CI que roda o mesmo gate (só quando o projeto não tem CI) |

Personas: `docs/fabrica/personas/` deste repositório (as mesmas que o `--review` lê), copiadas para o mesmo caminho no projeto.

## Adaptar

- A área `core` e o argumento de `check-feature.sh` são exemplos: troque pelos nomes das partes reais do projeto.
- A catraca `todo` conta `TODO` por arquivo. O baseline inicial nasce com `collie factory ratchet raise todo --reason "baseline inicial (factory init)"`; `update` só grava melhorias. O `measure` roda com `set -o pipefail` e falha se a pasta medida não existe: troque a pasta pela do projeto, senão a catraca recusa em vez de medir nada.
- **Protegidos** (o juiz recusa a tentativa que os muda): `scripts/gate.sh` e as configs puras do runner citadas depois do `#` (`jest.config.js`, `vitest.config.ts`, `vite.config.ts`, `vitest.workspace.*`). Deixe só as que existem no projeto e acrescente toda config pura do runner que existe e falta (o doutor avisa de uma citada que não existe); copie o texto inteiro para a linha `run:` do CI (em YAML o `#` é comentário).
- **Só inspecionados** (o `gate.sh` lê, o texto do gate não cita): `package.json`. Uma tarefa que muda dependência ou script (`npm install x`) continua possível; se ela forçar sucesso por ali, o `gate.sh` falha.
- Limite: o juiz compara por substring, então citar `jest.config.js` também protege um `x/jest.config.js`.
- Limite: o gate não enxerga binários em pastas ignoradas como node_modules/.bin ou .venv (nem .build; o `git diff` não os lista); um runner trocado ali passa. Quem pega é o revisor ou o CI, que instala do zero.
- `destructive`, `budgetSeconds`, `maxTries` e `land` vêm da entrevista; os valores daqui são o ponto de partida.
