# Modelo de fábrica: swift

- **Dono:** Ysrael Moreno (repositório Collie). Mudança no modelo passa por revisão como código.
- **Versão do modelo:** 1, de 2026-11-23.
- **Usado por:** `/collie:factory init` (`docs/fabrica/skill/factory-init/SKILL.md`), que copia daqui sem sobrescrever nada.

## O que tem

| Arquivo | Vai para | Para quê |
|---|---|---|
| `profile.json` | `collie-work.json` (mesclado) | gate, precheck, smoke, áreas e o perfil `factory` (U1) |
| `scripts/gate.sh` | `scripts/gate.sh` | o `gate` (`bash scripts/gate.sh`): roda `swift test`. O juiz protege por substring todo arquivo que o texto do gate cita: este script. O `swift test` não tem config pura de runner e o manifesto `Package.swift` fica fora do texto de propósito: uma tarefa que acrescenta dependência ou target continua possível (quem vê um target de teste removido é o revisor) |
| `scripts/check-feature.sh` | `scripts/check-feature.sh` | check de UMA tarefa: roda só os testes dela e falha se nenhum rodou; nunca só compila |
| `ci.yml` | `.github/workflows/ci.yml` | esqueleto de CI que roda o mesmo gate (só quando o projeto não tem CI) |

Personas: `docs/fabrica/personas/` deste repositório (as mesmas que o `--review` lê), copiadas para o mesmo caminho no projeto.

## Adaptar

- A área `core` e o argumento de `check-feature.sh` são exemplos: troque pelos nomes das partes reais do projeto.
- A catraca `todo` conta `TODO` por arquivo. O baseline inicial nasce com `collie factory ratchet raise todo --reason "baseline inicial (factory init)"`; `update` só grava melhorias. O `measure` roda com `set -o pipefail` e falha se a pasta medida não existe: troque a pasta pela do projeto, senão a catraca recusa em vez de medir nada.
- **Protegido** (o juiz recusa a tentativa que o muda): `scripts/gate.sh`. **Não protegido:** `Package.swift` (manifesto). Copie o texto inteiro do gate para a linha `run:` do CI.
- Limite: o gate não enxerga binários em pastas ignoradas como node_modules/.bin ou .venv (nem .build; o `git diff` não os lista); um runner trocado ali passa. Quem pega é o revisor ou o CI, que instala do zero.
- `destructive`, `budgetSeconds`, `maxTries`, `land` e `autoLandPerDay` (A5: quantos auto-lands o cercado pode fazer em 24 h, de 1 a 20; padrão 3) vêm da entrevista; os valores daqui são o ponto de partida.
