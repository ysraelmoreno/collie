# Modelo de fábrica: python

- **Dono:** Ysrael Moreno (repositório Collie). Mudança no modelo passa por revisão como código.
- **Versão do modelo:** 1, de 2026-11-23.
- **Usado por:** `/collie:factory init` (`docs/fabrica/skill/factory-init/SKILL.md`), que copia daqui sem sobrescrever nada.

## O que tem

| Arquivo | Vai para | Para quê |
|---|---|---|
| `profile.json` | `collie-work.json` (mesclado) | gate, precheck, smoke, áreas e o perfil `factory` (U1) |
| `scripts/gate.sh` | `scripts/gate.sh` | o `gate` (`bash scripts/gate.sh # pytest.ini`): roda o runner direto e falha se `conftest.py` (qualquer pasta), `pyproject.toml`, `pytest.ini`, `setup.cfg` ou `tox.ini` força sucesso (`passWithNoTests: true`, `testFailureExitCode: 0`, `--co`/`--collect-only`, `_exit(0)`, `exitstatus = 0`/`False`/`(`/`ExitCode.OK` como atribuição, fora de comentário: `#` em `.py`/`.ini`/`.toml`/`.cfg`, `//` em `.js`/`.ts`) ou é link simbólico, olhando o que o git lista: versionados, não versionados e também os ignorados (`.gitignore` ou `.git/info/exclude`) com nome de config, fora de venv (pasta com `pyvenv.cfg`), `node_modules/`, `.tox/` e `site-packages/`; um comentário no fim da linha (`addopts = "-q"  # sem --co`) não conta; um link fora das configs (`CLAUDE.md -> AGENTS.md`) não conta, um link para pasta só conta quando o alvo sai do repositório (`.claude/skills -> ../.agents/skills` passa); falha também com `pytest.py` ou `pytest/` na raiz e roda `python3 -P -m pytest` com Python 3.11+ e `python3 -I -m pytest` abaixo disso (isolado: sem a pasta atual no `sys.path`, então `pluggy.py` ou `_pytest/` na raiz não substituem o pytest; ignora as variáveis `PYTHON*` e o site do usuário, então o pytest vem do venv ou do sistema); o `check-feature.sh` faz a mesma escolha. O juiz protege por substring todo arquivo que o texto do gate cita: este script e as configs puras do runner depois do `#` |
| `scripts/check-feature.sh` | `scripts/check-feature.sh` | check de UMA tarefa: roda só os testes dela e falha se nenhum rodou; nunca só compila |
| `ci.yml` | `.github/workflows/ci.yml` | esqueleto de CI que roda o mesmo gate (só quando o projeto não tem CI) |

Personas: `docs/fabrica/personas/` deste repositório (as mesmas que o `--review` lê), copiadas para o mesmo caminho no projeto.

## Adaptar

- A área `core` e o argumento de `check-feature.sh` são exemplos: troque pelos nomes das partes reais do projeto.
- A catraca `todo` conta `TODO` por arquivo. O baseline inicial nasce com `collie factory ratchet raise todo --reason "baseline inicial (factory init)"`; `update` só grava melhorias. O `measure` roda com `set -o pipefail` e mede `.` inteiro (só `*.py`, fora `.venv`): restrinja à pasta do código se o projeto tiver outras com `TODO` que não importam.
- **Protegidos** (o juiz recusa a tentativa que os muda): `scripts/gate.sh` e as configs puras do runner citadas depois do `#` (`pytest.ini`). Deixe só as que existem no projeto e acrescente a que existe e falta (o doutor avisa de uma citada que não existe); copie o texto inteiro para a linha `run:` do CI (em YAML o `#` é comentário).
- **Só inspecionados** (o `gate.sh` lê, o texto do gate não cita): `pyproject.toml`, `setup.cfg`, `conftest.py`, `tox.ini` (que também guarda dependências e `[flake8]`, não é config pura do runner). Uma tarefa que muda dependência, cria fixture ou env do tox continua possível; se ela forçar sucesso por ali, o `gate.sh` falha.
- Layout plano (o código na raiz, sem `conftest.py` na raiz): com `-P` a raiz sai do `sys.path` e o import do código falha. Declare `pythonpath = ["."]` em `[tool.pytest.ini_options]` do `pyproject.toml` (ou `pythonpath = .` no `pytest.ini`).
- Limite: o juiz compara por substring, então citar `pytest.ini` também protege um `x/pytest.ini`.
- Limite: o gate não enxerga binários em pastas ignoradas como node_modules/.bin ou .venv (nem .build; o `git diff` não os lista); um runner trocado ali passa. Quem pega é o revisor ou o CI, que instala do zero.
- Limite: dos arquivos ignorados (inclusive por `.git/info/exclude`) o gate só vê os que têm nome de config do runner e estão fora de venv, `node_modules/`, `.tox/` e `site-packages/`; um binário em pasta ignorada segue fora.
- Fora de um repositório git, ou sem `git` no PATH, o gate falha de propósito (ele olha o que o git vê). CI em Docker com `.git` no `.dockerignore` cai aqui: copie o `.git` para a imagem ou rode o gate fora do contêiner.
- `destructive`, `budgetSeconds`, `maxTries` e `land` vêm da entrevista; os valores daqui são o ponto de partida.
