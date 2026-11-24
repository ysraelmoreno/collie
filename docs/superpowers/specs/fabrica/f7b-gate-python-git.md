# F7b: gate.sh dos modelos (rodada 4, revisor 2)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-4.md` (revisor 2). Arquivos: `docs/fabrica/modelos/*`, `docs/fabrica/skill/factory-init/SKILL.md`, `Sources/CollieCore/FactoryDoctor.swift`, testes. Melhor esforço, sem tentar fechar o que o gate declara como limite.

1. (major M-A) python: abaixo de 3.11 o `gate.sh` e o `check-feature.sh` rodam `python3 -I -m pytest` (isolado: ignora o cwd e as variáveis); a partir de 3.11 `python3 -P -m pytest`. Corrija o comentário falso. O `check-feature.sh` usa a MESMA decisão (extraia a escolha para uma função/arquivo de
   fonte comum `scripts/py-run.sh` no modelo, usado pelos dois, ou repita com cuidado). Teste em `FactoryModelsTests` (ou no script de teste dos modelos, se já houver): `pluggy.py` e `_pytest/` na raiz com `os._exit(0)` NÃO podem dar exit 0 no gate (com Python < 3.11 e >= 3.11 se houver as duas versões; se só uma estiver
   disponível, teste a que houver e a escolha do comando por função pura).
2. (m-D) a lista de arquivos do git vai para um temporário (`git ls-files -z ... > "$t" || fail`) e o gate lê dele; erro do `git ls-files` derruba o gate; `trap` apaga o temporário; sem `git` no PATH a mensagem diz "git não encontrado" (diferente de "fora de um repositório git").
3. (m-E) link versionado só derruba o gate quando o `realpath` do alvo sai do repositório; link para pasta dentro do repo passa (`.claude/skills -> ../.agents/skills`).
4. (m-B) além do que o git vê, o gate soma `git ls-files -z -o -i --exclude-standard` filtrado pelos NOMES de config do runner (`conftest.py`, `pytest.ini`, `tox.ini`, `setup.cfg`, `pyproject.toml`, `jest.config.*`, `vitest.config.*`, `vite.config.*`, `package.json`), podando pastas
   com `pyvenv.cfg`, `node_modules/`, `.tox/`, `site-packages/`; mesmo grep e mesmas regras de link. Atualize a linha "Limite" do cabeçalho e dos README (ignorado por `.git/info/exclude` agora é visto; binário em pasta ignorada segue fora).
5. (m-C) tirar `vite.config.ts` e `tox.ini` do texto do `gate` dos `profile.json` e de `SKILL.md` (ficam só inspecionados pelo grep, como `package.json`); ajuste `FactoryModelsTests` (continuam citando `pytest.ini`, `jest.config.js`, `vitest.config.ts`).
6. Nits baratos: comentário no fim da linha `addopts = "-q"  # ...` não conta como `--co` (corte o trecho depois de `#` fora de aspas simples); `isRunnerConfig` cobre `jest.config.json` e `vitest.workspace.json`; documente no README que fora de um repositório git (ou sem `git`) o gate falha de propósito (CI em Docker com `.git` no `.dockerignore`).

Check: `scripts/check-fabrica-loop.sh f7b`. Commit ao final, só os arquivos da tarefa.
