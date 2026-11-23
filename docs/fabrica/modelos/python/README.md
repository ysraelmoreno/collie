# Modelo de fábrica: python

- **Dono:** Ysrael Moreno (repositório Collie). Mudança no modelo passa por revisão como código.
- **Versão do modelo:** 1, de 2026-11-23.
- **Usado por:** `/collie:factory init` (`docs/fabrica/skill/factory-init/SKILL.md`), que copia daqui sem sobrescrever nada.

## O que tem

| Arquivo | Vai para | Para quê |
|---|---|---|
| `profile.json` | `collie-work.json` (mesclado) | gate, precheck, smoke, áreas e o perfil `factory` (U1) |
| `scripts/gate.sh` | `scripts/gate.sh` | o `gate` (`bash scripts/gate.sh # pytest.ini pyproject.toml setup.cfg conftest.py tox.ini`): roda o runner direto e falha se um arquivo de config que o governa força sucesso (`passWithNoTests`, `testFailureExitCode`, `--co`/`--collect-only`, `ExitCode.OK`, `_exit(0)`, `exitstatus = 0`, fora de comentário) ou é link simbólico; falha também com `pytest.py` ou `pytest/` na raiz e roda `python3 -P -m pytest` (Python 3.11+). O juiz protege por substring todo arquivo que o texto do gate cita: este script e as configs da raiz depois do `#` |
| `scripts/check-feature.sh` | `scripts/check-feature.sh` | check de UMA tarefa: roda só os testes dela e falha se nenhum rodou; nunca só compila |
| `ci.yml` | `.github/workflows/ci.yml` | esqueleto de CI que roda o mesmo gate (só quando o projeto não tem CI) |

Personas: `docs/fabrica/personas/` deste repositório (as mesmas que o `--review` lê), copiadas para o mesmo caminho no projeto.

## Adaptar

- A área `core` e o argumento de `check-feature.sh` são exemplos: troque pelos nomes das partes reais do projeto.
- A catraca `todo` conta `TODO` por arquivo. O baseline inicial nasce com `collie factory ratchet raise todo --reason "baseline inicial (factory init)"`; `update` só grava melhorias. O `measure` roda com `set -o pipefail` e mede `.` inteiro (só `*.py`, fora `.venv`): restrinja à pasta do código se o projeto tiver outras com `TODO` que não importam.
- O texto do `gate` cita depois do `#` os arquivos de config da raiz que governam o runner: deixe só os que existem no projeto (o doutor avisa de um citado que não existe) e copie o texto inteiro para a linha `run:` do CI (em YAML o `#` é comentário).
- Limite: o gate não enxerga binários em pastas ignoradas como node_modules/.bin ou .venv (nem .build; o `git diff` não os lista); um runner trocado ali passa. Quem pega é o revisor ou o CI, que instala do zero.
- `destructive`, `budgetSeconds`, `maxTries` e `land` vêm da entrevista; os valores daqui são o ponto de partida.
