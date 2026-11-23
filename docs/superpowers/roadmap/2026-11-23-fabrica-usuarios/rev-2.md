# Revisão independente, rodada 2 da fábrica para usuários (sobre `3e555443..HEAD`, F1 a F4)

Resultado: revisor 3 (motor V1-V4, F4) **approve**; revisor 1 (núcleo ratchet/doctor/isca) **reject**; revisor 2 (skills, modelos, detector) **reject**. Achados NÃO conferidos linha a linha por mim.

## Revisor 1 (reject, 1 blocker)
- Rodada 1: BLOCKER 1, MAJOR 1, MAJOR 2, MINOR 1, 3, 4, 5, 6 e os nits: fixed. BLOCKER 2 (baseline em `.git`): partial. MINOR 2 (taxa por persona): partial.
- N1 BLOCKER (`FactoryCommands.swift:258-297`, `ProjectRoot.swift:9-19`): com a raiz do projeto igual ao home (ou ancestral), o daemon grava o baseline fora do sandbox onde o perfil estrito nega
  (`.zshenv`, `.zshrc`, `.ssh/authorized_keys`, `Library/LaunchAgents`, `EssentialPaths.swift:76-84,96`). Cenário: `~/collie-work.json` com baseline `.zshenv` e measure `echo 'curl ...|sh;: 1'`,
  depois `ratchet raise`: o daemon cria `~/.zshenv`. Correção: recusar a catraca quando a raiz for o home, ancestral do home, ou o baseline cair em caminho de `EssentialPaths`; teste com raiz = home e rel `.zshenv`.
- N2 minor: o teste prova `FactoryRatchet.measure`, não a ligação em `factoryRatchet` (`:321`): teste do roteador com `sandboxHome` definido e terminal livre deve dar `.unavailable` sem rodar nada.
- N3 minor (`FactoryBait.swift:231`): numerador da taxa por persona conta runs fora da camada review; usar `where r.caught && r.layer == .review`.
- N4 minor (`FactoryCommands.swift:38-40`): erro no arquivo de resultados esconde os escapes válidos das outras camadas; somar os escapes dos runs que passam no parse isolado.
- N5 minor (`:199`): `(try? h.read(...)) ?? Data()` trata EIO como arquivo vazio e o `raise` reescreve o baseline perdendo o log; propagar o erro.
- N6 nit: baseline regravado vira 0600 (era 0644); sem `fsync` antes do `renameat`; parser aceita `~x`/`$x` que `target` recusa (uma função só); comentário "F1 (minor 6)" no teste errado; squash de `db70503b` com `2661d20f` (o primeiro não compila sozinho).

## Revisor 2 (reject, 2 majors)
- N1 MAJOR (`modelos/python/scripts/gate.sh:13-18`, `modelos/node/scripts/gate.sh:13-19`): o grep só acha `passWithNoTests|exitstatus *= *0`, só em arquivos regulares, só nos nomes listados. Desvios que saem com exit 0 (rodados com stubs):
  `pytest.ini` com `addopts = --co`; `conftest.py` com `session.exitstatus = pytest.ExitCode.OK` (ou TAB antes do `=`); `addopts = -p evil` + `evil.py`; um `pytest.py` commitado na raiz (arquivo novo, `tampered` nunca vê);
  `package.json` com `"jest": {"testFailureExitCode": 0}`; `jest.config.js` symlink; `jest.config.js` com `require("./cfg.json")`. Correção: citar no texto do `gate` os arquivos de config existentes (`"gate": "bash scripts/gate.sh # package.json jest.config.js ..."`),
  porque `tampered` (`WorkLoop.swift:984`) protege por substring; ampliar o grep (`testFailureExitCode`, `--co\b|--collect-only`, `ExitCode.OK`, `_exit(0)`, `exitstatus\s*=\s*0`); `-type f -o -type l`; python falha se houver `pytest.py` ou `pytest/` na raiz (ou `python3 -P -m pytest`).
- N2 MAJOR pré-existente (limite do motor, NÃO corrigir na fábrica): runner trocado em pasta ignorada (`node_modules/.bin/jest` com `exit 0`) é invisível ao `git diff` e ao `tampered` (`WorkLoop.swift:1022-1024`). Vira cartão.
- N3 minor (`FactoryDoctor.swift:132-146,159`): doctor dá 3 quando só o precheck/smoke cita arquivo; só as citações do `gate` contam.
- N4 minor (`:159-164`): `gate.sh` que só repassa para `npm test` ainda vale 3; se o runner achado for `npm|yarn|pnpm (run )?test`, limitar a 2.
- N5 minor (`node/scripts/gate.sh:18-19`, `check-feature.sh:9`, `factory-init/SKILL.md:52`): runner escolhido em tempo de execução por grep em `package.json` (editável) e fallback `npx jest` baixa da rede; a init grava o runner fixo em `gate.sh` (`npx --no-install <runner>`) e recusa runner que passe por script do `package.json`.
- N6 minor (`python/ci.yml:13-15`): perdeu `pip install -e ".[dev]"`; usar `pip install -e ".[dev]" 2>/dev/null || pip install -e .`.
- N7 nit: grep dá falso positivo em `"passWithNoTests": false` e em comentário (`# never set exitstatus = 0`); casar `passWithNoTests"?\s*[:=]\s*true` e ignorar comentário.
- N8 nit: detector: `"no test specified"` por substring; `yarn.lock` + `package-lock.json` vira yarn sem aviso; `bun.lockb` dá `None`.
- N9 nit: nenhuma isca exercita mais a camada judge (`FactoryBaitTests.swift:52`): isca nova com `collie-work.json` cujo gate cita `scripts/check-isca.sh`, `expect: guard`.
- N10 nit: `forced -name Package.swift` no gate swift não protege nada; README python diz que o measure falha se a pasta não existe, mas mede `.`.
- Abertos da rodada 1: nit `pushDefault`/pre-push na cópia da isca; nit patches Swift sem target.

## Revisor 3 (approve)
Minors 1 a 4 da rodada 1: fixed. Resta: se a gravação do trust desiste após 2 corridas, os revisores dessa execução podem cair no diálogo de trust (minor, opcional: tentar de novo uma vez); `access.request` de revisor com `--read` ou args inválidos recebe a mensagem "nada é liberado" (nit).
