# PRD C3: escalada de modelo no laço (`--escalate`)

PRD geral: `README.md` desta pasta. Depende de C2 (mesmo `WorkLoopCommands.swift`) e A2 (`--model` no preset `cursor`).

## Problema

O laço já dá a cada tentativa um agente novo (`<trabalho>-<tarefa>-t<n>`) com o mesmo `--preset/--model/--command`
para todas. Com um modelo barato isso gasta as `--tries` repetindo o mesmo erro. O que se quer: começar barato e subir
só na tarefa que o barato não resolve.

## Comando

```
collie work run --max <n> --escalate cursor:composer-2.5,cursor:gpt-5.6-luna-high,claude:sonnet [--tries 3] …
```

- Lista de `agente:modelo` (agente ∈ `claude|cursor`; Codex fica de fora até ter `--model`). Cada entrada é validada
  como no `summon --model` (A2), antes do cartão.
- A tentativa `n` de uma tarefa usa a entrada `min(n, k) - 1` (k = tamanho da lista). `--tries` continua sendo o teto.
- `--escalate` exclui `--preset/--model/--command` (recusa os dois juntos).
- O cartão do dono mostra a lista. O diário registra o modelo de cada tentativa; `collie work status` mostra o modelo da
  tentativa em curso.
- A nota de falha da tentativa anterior (já entregue ao próximo agente hoje) vale também quando o modelo muda.

## Fazer

`Sources/CollieDaemonKit/WorkLoopCommands.swift` (parse e validação), `Sources/CollieDaemonKit/Work/WorkLoop.swift`
(escolha do agente por tentativa, onde hoje sai o `summon` do laço, `WorkLoopCommands.swift:672`),
`Sources/CollieDaemonKit/Work/WorkStatusText.swift` (o modelo na linha "em laço"), `docs/referencia.md`.

## Fora deste PRD

- Escalada no `ask --check` (C1): o ask fala com um terminal que já existe; trocar o modelo dele é outra coisa
  (`collie model`, só Claude). Rever depois de medir o laço.
- Melhor-de-N com faixas: ver README, não-objetivos.

## Aceite

- `--escalate a,b,c --tries 3`, falha nas duas primeiras: tentativas com a, b, c (teste com host falso).
- `--tries 5` com 2 entradas: a, b, b, b, b (teste).
- `--escalate` com `--model`: recusado (teste).
- Entrada `codex:x`: recusada (teste).

## Check

```
swift test --disable-sandbox --filter WorkLoopTests && swift test --disable-sandbox --filter WorkLoopCommandTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
