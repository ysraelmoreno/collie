# F3: skills, modelos e detector (majors 1 e 2 do revisor 2 e minors)

Leia `docs/superpowers/roadmap/2026-11-23-fabrica-usuarios/rev-1.md` (revisor 2). Arquivos: `docs/fabrica/skill/*/SKILL.md`, `docs/fabrica/modelos/*`, `docs/fabrica/iscas/catalogo.json`, `scripts/factory-detect.sh`, `scripts/test-factory-detect.sh`.

1. factory-init, passo 4: o baseline inicial é `collie factory ratchet raise <nome> --reason "baseline inicial (factory init)"`; `update` só para melhorias; ajuste o texto do arquivo de baseline que "entra no repositório".
2. Modelos: o gate de cada stack cita os arquivos que o controlam e roda o runner direto: crie `scripts/gate.sh` por modelo (swift: `swift test`; node: `npx jest`/`npx vitest run` conforme o detector; python: `python3 -m pytest -q`)
   e o `gate` do `profile.json` é `bash scripts/gate.sh`; o `scripts/gate.sh` começa com um comentário listando os arquivos de config que o governam (`package.json`, `jest.config.*`, `conftest.py`, `pyproject.toml`, `Package.swift`) e
   falha se algum deles contiver `passWithNoTests`/`exitstatus` forçando sucesso (grep simples). `check-feature.sh` de node chama o runner direto (sem `npm test --`). Ajuste `FactoryModelsTests` para a nova regra do judge (gate que cita arquivo versionado) sem baixar a nota esperada.
3. Detector: `glob.escape(root)` (caminho com `[`, `]`, `*`, `?`) com caso novo no `test-factory-detect.sh`; capturar `RecursionError` e qualquer exceção de parse (sai JSON válido com o sinal ausente, nunca traceback) com caso novo; o texto padrão do `npm init`
   (`echo "Error: no test specified" && exit 1`) conta como sem testRunner; informar o gerenciador (`npm`, `pnpm`, `yarn`) pelo arquivo de lock.
4. Isca `spec-editado`: mude para `layer: review`, `expect: veto` e documente na descrição que o juiz não protege o check da tarefa; ajuste o teste do catálogo e a skill (`factory-bait/SKILL.md:49`).
5. factory-bait: declare na descrição que o catálogo vem do repositório (a factory-init copia `docs/fabrica/iscas/` do Collie para o projeto quando o dono pede isca) e confira que a cópia fica fora do repositório real (`case "$COPIA" in "$REAL"/*) exit 1;; esac`); use o campo `patch` do catálogo.
6. Modelos de CI: `permissions: { contents: read }`; python instala pytest explicitamente; node usa o gerenciador detectado (sem `cache: npm` fixo quando não há `package-lock.json`). Catraca `todo`: `measure` com `set -o pipefail` e erro se a pasta não existe; README avisa.

Check: `scripts/check-fabrica-loop.sh f3`. Commit ao final, só os arquivos da tarefa.
