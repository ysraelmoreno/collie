# Revisão independente, rodada 1 da fábrica para usuários (U1 a U5, mais V1 a V4)

Data: 2026-11-23. Intervalo: `fa2d8607..HEAD` (U1 a U5) e `d18740be..d94530f2` (V1 a V4). Três revisores opus, somente leitura. Achados ainda NÃO
conferidos linha a linha por mim, exceto os marcados (conferido). Critério de saída: uma rodada sem blocker nem major.

## Revisor 1, núcleo Swift (U1, U3, U4, U5): reject

- BLOCKER 1 (conferido): `Sources/CollieDaemonKit/FactoryCommands.swift:256-257`, `factory ratchet` roda o `measure` (comando do `collie-work.json`, conteúdo que um
  agente escreve) com `checkEnv(..., sandbox: nil)` e `runCheck(..., profile: nil, ...)`: sem `sandbox-exec`, com o HOME real. O laço, os serviços e o git rodam sob perfil.
  Cenário: agente edita o perfil com `measure: "cat ~/.ssh/id_ed25519 > ./k; echo a 1"` e roda `collie factory ratchet check x`. Correção: com `config.sandboxHome != nil`,
  rodar sob o perfil do terminal/paddock e `SandboxLaunch.environment` com o HOME do sandbox, como o laço (`RouterLoopHost.check`/`profile()`); sem perfil, recusar. Teste: sandboxHome
  definido implica `runCheck` com profile não nil.
- BLOCKER 2 (conferido): `FactoryProfile.swift:200-203` (`confinedPath`) e `FactoryCommands.swift:153-164` (`target`), `176-189` (`write`): o baseline aceita qualquer componente, inclusive
  `.git`; quem grava é o daemon, sem as negações de `SandboxProfile.swift:226-228` (`.git` aninhado, regra R17). Cenário: `baseline: "sub/.git"`, `measure: "echo 'gitdir: /proj/evil 1'"`,
  `raise` grava `sub/.git`; o `git status` do usuário executa `core.fsmonitor` fora do sandbox. Correção: recusar no parser e em `target` componente `.git` ou `*.git`, `.collie`, e o próprio
  `collie-work.json`; recusar também componente vazio e `.` (alinhar parser e `target`).
- MAJOR 1 (conferido): `FactoryBait.swift:172-174` só valida `cost >= 0`; `reduce(0) { $0 + ... }` (`FactoryCommands.swift:126`, `FactoryBait.swift:216`) estoura e faz trap, derrubando o
  daemon. Correção: teto no parse (`<= 86400 * 7`) e soma com saturação (`addingReportingOverflow`).
- MAJOR 2: TOCTOU na pasta do baseline (`FactoryCommands.swift:159-162` contra `181-185`): `target` resolve a pasta por realpath, depois `createFile(tmp)`/`rename` seguem o caminho de novo
  pelo nome; o `lstat` só olha o último componente. Cenário: outro terminal alterna `d` entre pasta e symlink para `~`; `rename` sai do projeto. Correção: `open(O_DIRECTORY|O_NOFOLLOW)`
  componente a componente (`openat`) e `openat(O_CREAT|O_EXCL|O_NOFOLLOW)` + `renameat` relativos a esse fd; no mínimo revalidar o fd do diretório antes do `renameat`.
- MINOR: (1) run escapado com `layer: null` não derruba nada no doctor (`FactoryBait.swift:170,175`; exigir `layer` também quando `caught` é false). (2) taxa por persona usa todos os runs
  como denominador (`:200-203`; usar só os runs da camada review). (3) `runsTests` não reconhece `npm run test:ci`, `yarn test:unit`, `bundle exec rspec`, `python -m unittest`, `make check`
  (`FactoryDoctor.swift:102-106`). (4) `onlyLooksForFiles` ignora o formato típico de check fraco (`|| exit 1`, `echo ok` final) (`:187-197`). (5) judge dá nota 3 para script citado que não
  existe no repositório (`:126-131`; conferir contra `s.paths`). (6) `update` zera o baseline quando o `measure` sai 0 com saída vazia (`FactoryCommands.swift:222-228`; recusar medição vazia
  sobre baseline não vazio).
- NIT: CRLF no baseline é recusado; chave que começa com `#` é descartada sem aviso; log do `raise` cresce sem limite (passa de 1 MB e a catraca trava); dois `raise` simultâneos perdem uma linha;
  qualquer arquivo com "baseline" no nome conta como catraca; `ciCiting` por substring; `bait-results.json` inválido derruba o doctor inteiro; `listPaths` para em 5000.

## Revisor 2, scripts, skills e modelos (U2, U4): reject (sem blocker)

- MAJOR 1: `docs/fabrica/skill/factory-init/SKILL.md:61` manda `collie factory ratchet update <nome>` para gravar o baseline inicial, mas `update` só abaixa (`FactoryCommands.swift:221-224`): com
  N>0 ocorrências dá "piorou", com 0 não cria o arquivo. Correção: primeiro baseline com `raise <nome> --reason "baseline inicial (factory init)"`; `update` só para melhorias.
- MAJOR 2: gates dos modelos são comandos nus (`npm test`, `python3 -m pytest -q`, `swift test`; `docs/fabrica/modelos/*/profile.json:3`, `node/scripts/check-feature.sh:8`); `WorkLoop.tampered`
  (`WorkLoop.swift:978-990`) só protege arquivos citados no texto do gate; o agente troca `"test"` por `"echo ok"` no `package.json` e o doctor ainda dá 3 ao juiz. Correção: gate que cita os
  arquivos que o controlam (`scripts/gate.sh` que chama o runner direto; citar `package.json`, `jest.config.*`, `conftest.py`, `pyproject.toml`, `Package.swift`); `check-feature.sh` de node chama o runner
  direto, sem `npm test --`; e o doctor NÃO dá 3 no judge quando o gate não cita nenhum arquivo versionado.
- MINOR: detector erra em silêncio com `[ ] * ?` no caminho (`scripts/factory-detect.sh:18`, usar `glob.escape`); `package.json` muito aninhado derruba o detector (`:31-32`, capturar
  `RecursionError`); `npm init` padrão vira `testRunner: "npm test"` (`:38`, tratar o texto padrão como ausência); isca `spec-editado` espera um guarda que não existe (`catalogo.json:16-18`,
  `factory-bait/SKILL.md:49`: ou `layer: review`/`expect: veto`, ou criar na cópia um `collie-work.json` cujo gate cita o script); a skill factory-bait só funciona no repositório do Collie
  (declarar na descrição, ou a init copiar `docs/fabrica/iscas/`); CI python não instala pytest sem o extra `dev` (`ci.yml:11`); CI node quebra fora do npm (`cache: npm`, `npm ci`);
  CI sem `permissions: contents: read`; catraca `todo` mede nada se a pasta não existe (`set -o pipefail` ou teste de existência).
- NIT: `npm test -- X` com `"test": "jest && eslint ."`; conferir que a cópia da isca fica fora do repositório real; `pushDefault` inválido ou hook `pre-push` na cópia; patches Swift sem target.

## Revisor 3, motor V1 a V4: approve (só minors)

- MINOR 1: `access.request` de um revisor do laço responde `shown: true` ("Pedido mostrado ao usuário") embora o `hush` o engula (`SandboxCommands.swift:41-45`, `:163`). Devolver `shown: false` com
  mensagem própria.
- MINOR 2: o teste da V4 (`WorkCommandTests.swift:487-505`) não falharia se todas as negações fossem silenciadas; acrescentar a expectativa de que a de um terminal comum gera cartão e a de uma faixa
  segue como hoje.
- MINOR 3: V3 lê, modifica e grava `~/.claude.json` sem checar mudança no meio (`WorkLoopReview.swift:357-391`); antes do `rename`, comparar `stat` (inode, tamanho, mtime) com o do início e tentar de novo
  ou desistir com nota. MINOR 4: falta `F_FULLFSYNC` antes do `rename` (`:389-390`). MINOR 5: symlink em `~/.claude.json` seguido pelo daemon (decisão do dono; NÃO mudar sem ele).
- NIT: reescreve o arquivo inteiro (ordem de chaves); ACL e xattrs se perdem; `loopReviewers` não é limpo se o revisor sai por outro caminho.
