# B2.4 O agente não reescreve o script que o julga

Achado 2 da revisão da onda 2 (`.collie/briefs/rev-wave2-report.md`, local). O comando do portão e o do check ficam fixos no registro, mas o arquivo que eles executam (por exemplo `scripts/ci/lint.sh`) está no repositório e o agente pode trocá-lo por `exit 0` no próprio commit.

## Fazer

1. No veredito da tentativa (em `WorkLoop.swift`, junto da validação de `judged..before` do B2.3), reprovar quando `git diff --name-only <before> <judged>` contém um caminho que aparece **literalmente** no texto do check ou do portão. Razão em português: "a tentativa alterou «<caminho>», que o check/portão executa".
2. A comparação é por caminho completo como substring do texto do comando (o caso `scripts/ci/lint.sh`); não precisa interpretar o shell.
3. Documentar a limitação em `LoopCommand.swift` (texto de `/collie:loop`) e em `docs/referencia.md`, em uma frase: "um check ou portão que chama um script do repositório só vale se a tarefa não altera esse script; o laço reprova a tentativa que o altera".
4. Uma tarefa cuja spec manda criar justamente esse script (como o A2.1 criando `lint.sh`) falharia sempre: então a trava só vale para o **portão** e para caminhos que já existiam em `before` (`git cat-file -e <before>:<caminho>`). Criar o arquivo pela primeira vez não reprova.

## Testes (`WorkLoopTests`)

- tentativa que altera `scripts/ci/lint.sh` já existente, citado no portão: reprova com a razão.
- tentativa que cria o script citado pela primeira vez: passa.
- tentativa que altera um arquivo não citado: passa.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência nova. Textos em português. Commits convencionais; nada de push. Não tocar em `scripts/ci/`.
