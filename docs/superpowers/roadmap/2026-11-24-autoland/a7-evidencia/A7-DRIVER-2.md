# A7: lote 2 (S2 a S5), cercado `e2e-fabrica`

Você é o Pastor do cercado `e2e-fabrica`. Base: `~/Documents/codes/collie-e2e/e2e1/repo`. Remoto: `~/Documents/codes/collie-e2e/e2e1/origin.git`. Nunca `git push`, nunca `paddock land` à mão. Só o laço integra. Não edite arquivos do cercado à mão, exceto `git merge main` entre cenários. Em cada cenário: espere com `collie work wait` em segundo plano (não prenda o terminal), grave o resultado em `RESULTS-<cenário>.md` em `~/Documents/codes/collie-e2e/e2e1/` e continue.

## Antes de cada cenário
`git status --short` limpo; `git merge main --no-edit`; anote `git -C <base> rev-parse HEAD` como BASE0 e `git -C <origin.git> log --oneline` (o remoto NUNCA pode ganhar commit).

## Em cada cenário grave
`collie work status --events 100` (antes de fechar o trabalho), as `notes` do trabalho, `git -C <base> log --oneline -4`, o `stopReason`, e uma linha: ESPERADO x OBTIDO. Fechar: `collie work done` (se pedir confirmação ou houver tarefa adiada, descreva e siga).

## S2: portão vermelho (spec `specs/s2-gate-vermelho.md`)
`collie work start "S2 portao"`; `collie work task add "S2 sub" --spec specs/s2-gate-vermelho.md --check 'grep -q "def sub" calc.py'`; `collie work run --max 3 --tries 2 --review --auto-land`.
ESPERADO: nada integrado (BASE0 inalterada); a tarefa não fica `done` enquanto o portão estiver vermelho (reprovada/adiada), ou, se o agente corrigir o 99, `landed`. Registre qual dos dois e por quê.

## S3: veto de revisão (spec `specs/s3-veto.md`)
`collie work start "S3 veto"`; task `--check 'grep -q "def average" calc.py'`; mesmo `work run`.
ESPERADO: a persona `correcao` veta (major, divisor `len+1`) na tentativa 1; ou a tentativa 2 corrige e depois `landed`, ou esgota e a tarefa é adiada (sem land). Registre o parecer (persona, arquivo:linha).

## S4: a base anda no meio (spec `specs/s4-base-andou.md`)
`collie work start "S4 base"`; task `--check 'python3 -m unittest discover -s tests -t . -q && grep -q "def neg" calc.py'`; `collie work run ...` igual. ASSIM QUE `collie work status` mostrar o agente trabalhando, faça no repositório BASE (não no cercado): `git -C <base> commit --allow-empty -m "e2e: base andou"`. Espere o fim.
ESPERADO: `stopReason` `landBaseMoved` (a base andou desde a tentativa), NADA integrado, o commit externo continua na base.

## S5: aceite (spec `specs/s5-aceite.md`)
S5a: `work start "S5a aceite vermelho"`; task `--check 'python3 -m unittest discover -s tests -t . -q && grep -q "def div" calc.py' --accept 'false'`; `work run` igual. ESPERADO: o aceite vermelho reprova a tentativa (`acceptFailed`), sem land.
S5b: `work start "S5b aceite verde"`; mesma task com `--accept 'python3 -c "import calc; assert calc.div(8,2)==4"'`; ESPERADO: `landed` e o resumo mostra o aceite.
