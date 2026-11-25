# PRD B2: app mostra a árvore de Pastores e revoga

PRD geral: `README.md` desta pasta. Depende do B1 (`TerminalRecord.summonedBy`).

## Problema

Com sub-Pastores, o dono precisa ver quem convocou quem e poder cortar um ramo. Hoje `AgentTree`
(`Sources/CollieApp/AgentTree.swift`) tem só dois níveis (`depth` 0: raiz; 1: sob um Pastor), montados pelas guias.

## Fazer (`Sources/CollieApp/AgentTree.swift`, a view que o desenha, `Tests/CollieAppTests/`)

1. `AgentTree` aninha por `summonedBy` quando houver: sub-Pastor sob o Pastor que o convocou, os workers dele sob ele
   (`depth` até 3). Sem `summonedBy`, a regra de hoje (guias).
2. Um sub-Pastor mostra o selo "Pastor" e, na dica, "convocado por <nome>".
3. No menu de um sub-Pastor: **Encerrar ramo** (a dispensa em cascata do B1, pelo comando de admin que o app já usa
   para fechar terminal, com a confirmação de hoje) e o interruptor de Pastor que já existe (desligar: ele deixa de
   convocar; os convocados ficam).
4. **Pastor marcado pelo usuário é Pastor de raiz.** Achado na revisão do B1 (`279e047d`): o daemon trata como
   sub-Pastor (sem `--paddock`, teto 6, profundidade contada) qualquer Pastor com `summonedBy`. Um worker convocado
   que o usuário marca como Pastor no app (o caso do `cursor-lead` em 2026-11-24) deve virar Pastor de raiz: o
   `terminal.update` com `shepherd: true` vindo do app (admin) limpa `summonedBy`
   (`Sources/CollieDaemonKit/CommandRouter.swift`, ~linha 788). Teste em `ShepherdTests`.

## Aceite

- `AgentTree` com Pastor → sub → 2 workers: linhas em ordem com `depth` 0, 1, 2, 2 (teste puro).
- Sem `summonedBy`: mesmas linhas de hoje (teste).

## Check

```
swift test --disable-sandbox --filter AgentTreeTests && swift test --disable-sandbox --filter ShepherdTests
```

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite>`, nunca a suíte inteira. Sem dependência
nova. Commit com mensagem convencional, só dos seus arquivos; nada de push.
