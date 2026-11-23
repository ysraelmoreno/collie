# Revisão independente, rodada 3 da fábrica para usuários (sobre `3f01dfc2..HEAD`, F5a e F5b)

Resultado: revisor 1 (núcleo) **reject** (2 majors); revisor 2 (modelos/detector) **reject** (2 majors, ambos falso positivo). Achados NÃO conferidos linha a linha por mim.

## Revisor 1 (núcleo)
- Fixed: N2, N3, N4, N5, doctor (rev2 N3/N4). N1 partial. N6 partial (resta o squash de `db70503b` com `2661d20f`, só cosmético).
- A MAJOR: TOCTOU entre `place` (resolve a raiz com `realPath`, `FactoryCommands.swift:175`) e `openDir` (`:189`, `open(O_DIRECTORY)` sem `O_NOFOLLOW`). Um terminal com cwd em `/private/tmp/proj` (gravável pelo perfil) troca a pasta por symlink para `~`
  em laço; o daemon grava `~/.zshenv` fora do sandbox.
- B MAJOR: `mayWrite` recebe o caminho NÃO resolvido (`:179`) e compara com diferença de caixa (`SandboxGrants.swift:56-61,65`); volume do macOS não diferencia caixa. Raiz `~/.config`, baseline `FISH/conf.d/x.fish`: passa e grava em `fish/conf.d`.
- C minor: `viaPackageScript` não pega `bun run test`, `npm t`, `npm run-script test` e só vê a primeira linha que roda testes (`FactoryDoctor.swift:93-100,167`).
- D/E/F nits: grants vazios dão falso positivo conservador; a raiz da catraca é calculada sem `home: sandboxHomeDir` e de `t.cwd` em vez de `rec.projectRoot`; sem `fsync` da pasta depois do `renameat`.
- Causa de fundo: o daemon grava por pedido de um agente onde o sandbox do agente negaria. Três rodadas, o mesmo tipo de achado. DECISÃO (F6a): o daemon só roda o measure sob sandbox e devolve o texto; o CLI grava no processo do agente.

## Revisor 2 (modelos, detector)
- N1 partial: `-p evil` e `require("./cfg.json")` seguem abertos (limite declarado no gate); N2 não cobrado (cartão); N3 a N10 e os nits da rodada 1: fixed. Isca `gate-editado` aplica e o `tampered` dispara. Detector sem defeito com 10 entradas hostis.
- M1 MAJOR (`modelos/{python,node}/scripts/gate.sh:22-23` / `:17-18`): `find . -type l` e o grep de configs olham o disco, não o git; só podam `.git`, `node_modules`, `.venv`, `.build`. `venv/`, `.tox/`, `.direnv/` e `CLAUDE.md -> AGENTS.md`
  deixam o gate sempre vermelho; um `conftest.py` instalado em `venv/lib/site-packages` com `exitstatus = 0` também. Mensagem enganosa. Correção: olhar só o que o git vê (`git ls-files -s | awk '$1==120000'` mais `git ls-files -o --exclude-standard` com `[ -L ]`; mesma lista para o grep), mensagem própria para link.
- M2 MAJOR (`modelos/*/profile.json:3` + `WorkLoop.swift:984`): citar `package.json`, `pyproject.toml`, `Package.swift`, `setup.cfg`, `conftest.py` no texto do gate faz o `tampered` recusar `npm install`, nova dependência, novo target, nova fixture. Tarefa sem spec que cite o arquivo nunca os muda.
  Correção: no texto do gate só as configs puras do runner (`jest.config.*`, `vitest.config.*`, `vite.config.*`, `pytest.ini`, `tox.ini`) e manter o grep para os manifestos; documentar nos README e na init.
- m3 (motor, `WorkLoop.swift:984`): `gate.contains(path)` é substring: `test.py`, `config.js`, `x.ini` ficam intocáveis. Aceitar e documentar (vira cartão).
- m4: `python3 -P` quebra layout plano (sem `conftest.py` na raiz) e Python < 3.11 (`Unknown option -P`); documentar `pythonpath = ["."]` e recuar para `-m pytest` com `PYTHONSAFEPATH=1`/checagem de versão.
- m5: variantes que a lista de palavras não pega (`exitstatus = False`, atribuição em várias linhas, `ExitCode(0)`, `sys.exit(0)`, `sitecustomize.py`); comentário em `.py`/`.ini` é só `#` (o filtro trata `//` como comentário). Melhor esforço: aceitar e registrar no `ponytail:`.
- m6: o texto do modelo node não cita `vite.config.ts`; a init só poda, nunca acrescenta os existentes.
- n1: falsos positivos da regex (`"testFailureExitCode": 1`, `if exitstatus == pytest.ExitCode.OK`); n2 assimetria de aviso (`jest.config.js` ausente derruba o judge para 1, `pytest.ini` ausente não); n3 = minor C.
