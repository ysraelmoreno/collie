# Aceite em runtime (`work task add --accept`)

O check de uma tarefa julga o código (compila, os testes passam). O aceite julga o **resultado rodando**: a tela abre,
o serviço responde, o fluxo passa. Não há framework: é um comando de shell, exit 0 = aceito.

```sh
collie work task add "Tela de login" --spec docs/specs/login.md \
  --check "swift test --filter LoginTests" \
  --accept "scripts/accept/login.sh" --accept-timeout 900
```

## Regras

- O comando fica no estado do trabalho, aprovado com a tarefa pelo dono. O agente não o recebe no prompt e o laço
  nunca o lê da worktree.
- Ordem na tentativa: check → portão → **aceite** → parecer. Roda na worktree da tentativa, no mesmo perfil de sandbox
  do check, depois que o agente foi dispensado (nada que ele deixou rodando atende o aceite). Check ou portão vermelho:
  o aceite não roda.
- Falha do aceite é falha de check: a tentativa conta e a saída inteira (sem segredos, até 64 KB, cabeça e rabo) vai
  para a nota que a próxima tentativa lê. Escreva saídas que digam o que faltou.
- O aceite sobe o que precisa e derruba no fim (`trap`): cada tentativa começa do zero.
- Se a tentativa alterar um arquivo que o comando cita (o script do aceite, por exemplo), ela é reprovada sem rodar,
  como no portão. Para a tarefa poder mudar o script, cite-o na spec.
- Com `--auto-land`, toda tarefa com `--accept` precisa do último aceite verde para o land (`landAcceptRed`).
- `factory.verification.scenarios` continua vazio no `factory doctor` (aviso): o aceite é por tarefa, não do perfil.

## Exemplos (não é framework; adapte)

Serviço HTTP do cercado:

```sh
#!/usr/bin/env bash
set -euo pipefail
swift run -c debug MeuServico --port 18080 & pid=$!
trap 'kill $pid 2>/dev/null' EXIT
for _ in $(seq 1 60); do curl -fsS localhost:18080/health && break; sleep 1; done
curl -fsS localhost:18080/api/itens | grep -q '"itens"'
```

App do cercado (serviço de app, `collie app`): suba o app pelo serviço do cercado e confira o que ele expõe, com
`collie app logs`/`collie app snapshot` lidos pelo script (grep da linha esperada).

Navegador: um script Playwright (ou `curl` na página) que abre a URL do app do cercado e procura o texto da tela:

```sh
npx playwright test e2e/login.spec.ts --reporter=line
```

Simulador/aparelho (`collie device`): instale o build, abra o app e procure o elemento na árvore de acessibilidade ou na
tela (`collie device list` mostra os aparelhos); falhe com exit ≠ 0 e uma linha do que não apareceu.
