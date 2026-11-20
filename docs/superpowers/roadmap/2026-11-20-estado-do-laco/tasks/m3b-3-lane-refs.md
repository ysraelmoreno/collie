# M3b.3 A faixa não move refs do repositório

Leia `onda3b.md` e o **achado 3** de `rev-onda3-report.md`. Código: `Sandbox/SandboxProfile.swift` (~120-122, 162-175, 187, 198-201, 229-236: `laneClosed`, as regras de `<common>`), `Tests/CollieDaemonKitTests/LaneHostTests.swift` (`ProfileRules`).

## Problema
O perfil da faixa abre `<common>/refs`, `<common>/logs`, `packed-refs` e `objects` inteiros para escrita: o agente da faixa pode mover qualquer branch (o do cercado, `main`), apagar reflog e contornar o integrador.

## Fazer
1. No perfil **da faixa** (não no do cercado, que fica como está), abrir para escrita só: `objects`, `refs/heads/collie/lane/<nome-da-faixa>` (e `.lock`), `logs/refs/heads/collie/lane/<nome-da-faixa>`, `logs/HEAD`, o gitdir da faixa. `packed-refs`, o resto de `refs/` e de `logs/` ficam **fechados** para escrita. Leitura do que o git precisa continua.
2. Confirmar que o git da faixa continua conseguindo `add`/`commit` no branch dela (teste com git real num repositório temporário, aplicando as regras do perfil como `ProfileRules`: o caminho que o commit grava está permitido) e que `git update-ref refs/heads/<outro>` e escrever `packed-refs` **não** estão.
3. Documentar em `docs/referencia.md` (seção do paralelismo): a faixa **lê** os commits de todas as branches (o object store é comum); só os arquivos não commitados do dono ficam fechados.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LaneRefsProfileTests.swift`
`ProfileRules` sobre o perfil gerado da faixa A: escrita permitida só nos caminhos acima; negada em `refs/heads/main`, `refs/heads/collie/<cercado>`, `refs/heads/collie/lane/<outra>`, `packed-refs`, `logs/refs/heads/main`, `refs/stash`, `hooks`, `config`; o perfil do cercado (sem faixa) **igual ao de antes** (regressão por texto). Um nome de faixa com caracteres especiais não escapa do regex do perfil. Os testes de `LaneHostTests` seguem verdes.
