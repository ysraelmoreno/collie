# A7: roteiro do cenário S1 (verde, landed)

Você é o Pastor do cercado `e2e-fabrica` (cercado fábrica de teste, descartável). Base: `~/Documents/codes/collie-e2e/e2e1/repo`. Remoto de prova: `~/Documents/codes/collie-e2e/e2e1/origin.git` (nada pode ser enviado a ele).
Regras: nunca `git push`, nunca `paddock land` à mão; só o laço integra. Não edite arquivos no cercado fora do que o laço faz. Respostas curtas.

1. No cercado: `git status --short` (deve estar limpo) e `git merge main --no-edit` (traz `specs/s1-mul.md`).
2. `collie factory doctor` e `collie paddock status e2e-fabrica`: anote as notas.
3. `collie work start "S1 verde"`.
4. `collie work task add "S1 mul" --spec specs/s1-mul.md --check 'python3 -m unittest discover -s tests -t . -q && grep -q "def mul" calc.py'`.
5. `collie work run --max 3 --tries 2 --review --auto-land` (o dono aprova o cartão no app, "sempre permitir"). Depois espere com `collie work wait` (em segundo plano, não prenda o terminal).
6. Ao fim, grave em `~/Documents/codes/collie-e2e/e2e1/RESULTS-s1.md`: `collie work status --events 100`, `collie work summary`, `git -C <base> log --oneline -6`, `git -C <origin.git> log --oneline`, e o caminho do resumo imutável do auto-land (0444). Diga em uma linha se `stopReason` foi `landed`.
Esperado: `landed`, merge na base (`mul` em `calc.py`), o remoto SEM commit novo.
