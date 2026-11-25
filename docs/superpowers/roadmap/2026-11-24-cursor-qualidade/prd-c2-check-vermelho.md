# PRD C2: check que já passa antes da tentativa é recusado

PRD geral: `README.md` desta pasta. Depende do C1.

## Problema

Na rodada 3 o líder Cursor propôs para o laço checks como
`python3 -m unittest test_slug.SlugifyTests.test_eszett_maps_to_ss`: o teste que julga a tarefa é escrito pelo próprio
agente na tentativa. Um teste trivial (ou que não existe e é criado vazio) passa, e o check não mede nada. O jeito
barato de pegar isso: um check que mede a tarefa **falha** antes dela.

## Regra

- Antes da primeira tentativa, o check roda no estado inicial (laço: o commit inicial da tarefa, na worktree ou na faixa;
  ask com portão: a pasta do alvo antes de enviar o prompt).
- **Exit 0 no estado inicial:** recusado, com `o check já passa antes da tarefa: não mede o que ela muda`.
- **Exceção explícita:** `--green-ok` (no `work task add` e no `ask --check`), para refatoração e tarefas em que o
  check deve continuar verde. O cartão do laço mostra `--green-ok` ao lado do check, para o dono ver.
- Check que não roda no estado inicial por falta de arquivo (exit ≠ 0): conta como vermelho, segue.

## Fazer

1. Laço: no `work run`, antes do cartão, rodar cada check aberto no HEAD do cercado (mesmo sandbox e timeout do check).
   Os recusados aparecem na resposta do `work run` e nada vai para o cartão até serem corrigidos ou marcados
   `--green-ok`. (`Sources/CollieDaemonKit/WorkLoopCommands.swift`, `Sources/CollieDaemonKit/Work/WorkStore.swift`
   para o campo da tarefa.)
2. Ask com portão (C1): o mesmo, antes de enviar o prompt.
3. `/collie:loop` (`Sources/CollieDaemonKit/Work/LoopCommand.swift`): uma frase no procedimento: o check deve falhar
   antes da tarefa; prefira asserts sobre o comportamento pedido (`python3 -c "assert …"`) a rodar um teste que a
   própria tarefa escreve.

## Aceite

- `work run` com uma tarefa cujo check é `true`: recusado, nada no cartão (teste).
- A mesma com `--green-ok`: vai para o cartão, marcada (teste).
- `ask --check "true"`: recusado; com `--green-ok`: enviado (teste).
- Check `false` no estado inicial: segue (teste).

## Check

```
swift test --disable-sandbox --filter WorkLoopCommandTests && swift test --disable-sandbox --filter AskCheckTests \
  && swift test --disable-sandbox --filter LoopCommandTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
