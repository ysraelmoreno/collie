# PRD C1: `ask` com portão (`--check`, `--spec`, `--tries`)

PRD geral: `README.md` desta pasta (problema 1, a parte da qualidade). Depende de A3 e A4.

## Problema

Na rodada 2, o builder (Composer 2.5) declarou pronto um `slugify` com bug conhecido: o reviewer apontou o caso
`Straße`, chamou de "ressalva", e nada obrigava o builder a resolver. Hoje o único juiz por comando é o laço
(`collie work run`): cartão do dono, commit obrigatório, worktree limpa, um agente novo por tentativa. É pesado demais
para "faça isto e só me responda quando passar".

## Comando

```
collie ask <alvo> "<pedido>" --check "<comando>" [--spec <arquivo.md>] [--tries 3] [--check-timeout 600]
```

- O prompt entregue é o pedido, mais (se houver) o caminho do spec, mais uma linha fixa:
  `O Collie roda este check quando você terminar e só aceita a resposta se ele passar: <comando>`.
- Fim do turno do alvo (hook, `collie reply` ou ociosidade, como hoje): o daemon roda o check na pasta do alvo, sob o
  sandbox do alvo (`WorkLoopCommands.runCheck`, `WorkLoopCommands.swift:757-775`, com o perfil do terminal e o
  `checkEnv` sem `COLLIE_*`).
- **Passou:** o ask termina com a resposta do alvo e `check: {status: "passed", tail}`.
- **Falhou:** o mesmo alvo recebe `O check falhou. Corrija e encerre o turno. Fim da saída:` + as últimas 40 linhas
  (até 3 KB, `LotBoards.scrub`, como o pré-check do laço: `WorkLoop.swift:127-130`). Conta uma tentativa.
- **Acabaram as tentativas:** o ask termina com `status: failed`, `error: "check failed after N tries"` e o fim da saída.
  O asker decide (escalar, refazer, aceitar).
- O check e o spec ficam no registro do ask (no daemon), não no repositório. Uma tentativa que altera um script que o
  check executa (caminho escrito no comando, já existente antes) é reprovada, mesma regra do portão do laço.
- `--no-wait` vale: a resposta só entra no inbox no fim (passou ou esgotou).
- Sem `--check`: o `ask` de hoje, sem nenhuma diferença.

## Fazer

1. Protocolo, CLI e MCP: os três argumentos novos (`Sources/CollieProtocol/Commands.swift`, ferramenta MCP `ask`).
2. `AskCoordinator`: um ask com portão não fecha no fim do turno; chama o check (por uma closure injetada, para teste) e
   reenfileira a correção para o mesmo alvo. Tentativa conta no registro do ask.
3. `AskInbox.Entry` e o resultado síncrono ganham `check` (`status`, `tries`, `tail`).
4. A orientação ensina a forma curta só para Pastor, se couber no limite.
5. `docs/referencia.md`: seção do ask.

## Aceite

- Check que falha 1× e passa na 2ª: o alvo recebe uma correção com o fim da saída; o ask termina `passed` com 2
  tentativas (teste com check falso).
- Check que sempre falha com `--tries 2`: `failed`, o fim da saída na resposta (teste).
- Tentativa que edita o script do check: reprovada com o motivo (teste).
- Sem `--check`: os testes de `AskTests` de hoje passam sem mudança.

## Check

```
swift test --disable-sandbox --filter AskTests && swift test --disable-sandbox --filter AskCheckTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
