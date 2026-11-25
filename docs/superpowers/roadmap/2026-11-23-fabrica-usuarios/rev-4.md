# Revisão independente, rodada 4 da fábrica para usuários (sobre `6ce26e0d..HEAD`, F6a e F6b)

Resultado: revisor 1 (redesenho do ratchet) **reject** (1 major); revisor 2 (modelos) **reject** (1 major). Achados NÃO conferidos linha a linha por mim.

## Revisor 1 (ratchet: o daemon mede, o CLI grava)
- Confirmado: o daemon não grava mais nada para o baseline; o MCP não grava (`factory.ratchet.*` com `exposedToMCP: false`). Rodada 3 A: partial; B: fixed; C: fixed com falso positivo novo (minor 2). Nit E e F: fixed.
- MAJOR 1: o CLI grava o `path` do daemon sem confinar e seguindo links nas pastas do meio (`Sources/collie/CLI.swift:109`; `Ratchet.swift:110-111` só exige `hasPrefix("/")` e abre a pasta com `open(dirname, O_DIRECTORY)` sem `O_NOFOLLOW` componente a
  componente). O admin ou um Shepherd pode usar `--terminal` para mirar outro terminal (`WorkCommands.swift:175-190`). Cenário: o usuário, em shell livre, roda `collie factory ratchet raise lint --reason x --terminal A`; o agente A, com sandbox,
  troca `metrics` por symlink para `~` entre a resposta e o `open` do CLI; o CLI, sem sandbox, segue o link e substitui `~/.zshenv`. Correção: o daemon devolve `root` e `rel` (não `path`); o CLI reaplica `FactoryProfile.confinedPath(rel)`,
  abre a pasta por `openat(O_DIRECTORY|O_NOFOLLOW)` componente a componente a partir da raiz (a raiz também com `O_NOFOLLOW`; mover `FactoryRatchet.openDir` para CollieCore e reusar), exige que `root` seja a raiz de projeto do cwd do PRÓPRIO CLI
  e recusa `update`/`raise` com `--terminal` de outro processo (ou só grava quando o CLI estiver no sandbox daquele terminal). Teste: pasta do meio como symlink no escritor dá erro e deixa o alvo intocado.
- MINOR 2 (`FactoryDoctor.swift:193`): `viaPackageScript` dá falso positivo em `bun test` (runner nativo do bun, não o script do package.json); o bun casa só com `bun run test`/`bun run t`. Nits: `npm run t`/`yarn t` casam mas rodam o script `t`; `npm -s test` e `npm --silent test` não casam.
- MINOR 3: sem teste do trecho do CLI (`CLI.swift:107-115`): extrair função pura `handleRatchet(result) -> (JSONValue, Int32)` e testar (newBaseline grava e `wrote: true`; erro do escritor sai 1 sem imprimir; `check` não grava).
- NIT 4: linhas `#` do baseline antigo escapam do filtro de controle (`Ratchet.swift:25`, `FactoryCommands.swift:264`); descartar ou recusar. NIT 5: o CLI não limita o tamanho de `newBaseline` (2 MiB de defesa extra).
  NIT 6: TOCTOU de leitura no daemon (`FactoryCommands.swift:256`); abrir a raiz uma vez e usar o mesmo fd. Spec F6a §2 fala de "instrução curta para o MCP" que não existe (os comandos não são expostos): atualizar a spec.

## Revisor 2 (modelos, F6b)
- M1, M2, m6, n1, n2: fixed (rodados com pytest real em Python 3.9.6/3.10/3.12 e git temporário; venv ignorado, `CLAUDE.md -> AGENTS.md`, tarefa que adiciona dependência: verdes; os desvios anunciados continuam pegos). m4: partial por causa do M-A.
- M-A MAJOR (`python/scripts/gate.sh:42-44`, `:10-14`, `check-feature.sh:8-10`): com Python < 3.11 (o `/usr/bin/python3` do macOS é 3.9; Ubuntu 22.04 é 3.10) um `pluggy.py`/`iniconfig.py`/`_pytest/`/`tomli.py` na raiz com `os._exit(0)` e um teste que falha
  dá exit 0; no 3.12 com `-P` fica vermelho. O comentário "older Python has no -P, the root check above covers it" é falso; `check-feature.sh` nem roda o `gate.sh`. Correção: abaixo de 3.11 rodar `python3 -I -m pytest` (3.9 com `pluggy.py` deu exit 1) ou o
  entrypoint `pytest` do venv; caso novo em `FactoryModelsTests`.
- m-B minor (`gate.sh:33`/`:28`, `--exclude-standard`): config IGNORADA fica invisível e quem decide o que é ignorado é o agente (`tests/conftest.py` não versionado com `exitstatus = 0` + `.git/info/exclude`; `lib/conftest.py` com `lib/` no `.gitignore`;
  `pytest.ini` ou `vitest.config.ts` ignorado). Correção: somar `git ls-files -z -o -i --exclude-standard` filtrado pelos nomes de config, podando pastas com `pyvenv.cfg`, `node_modules/`, `.tox/`, `site-packages/`; no mínimo documentar no "Limite".
- m-C minor: `vite.config.ts` e `tox.ini` não são configs puras (build do Vite; deps e `[flake8]` no tox); tirar os dois do texto do gate e deixá-los só inspecionados (`profile.json:3`, `SKILL.md:55-59`).
- m-D minor (`gate.sh:33`/`:28`): erro do `git ls-files` (ex.: `.git/index` corrompido) não derruba o gate (a process substitution engole o erro; a lista fica vazia). Correção: gravar a lista num temporário (`git ls-files -z ... > "$t" || fail`) e ler dele (sem `wait $!`: bash 3.2 do macOS).
- m-E minor (`gate.sh:31`/`:26`): link versionado para pasta DENTRO do repositório (`.claude/skills -> ../.agents/skills`) derruba o gate com mensagem falsa; só falhar quando o `realpath` do alvo sai do repositório.
- Nits: comentário no fim da linha (`addopts = "-q"  # do not add --co`) fica vermelho; `tox.ini` com `commands = pytest --collect-only` em outro env; fora de repositório git ou sem `git` no PATH o gate falha (fechado) com mensagem enganosa; `isRunnerConfig` não cobre `jest.config.json`/`vitest.workspace.json`.
