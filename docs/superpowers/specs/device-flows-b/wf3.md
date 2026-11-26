# wf3: container clicável de tela cheia, teto no teste do hangup, tolerância do pin

Onda f, menores da conferência da onda e (`.collie/briefs/rev-device-flows-onda-e.md`, achados 3, 4 e 5). Depende da wf2. Check: `scripts/check-device-flows-wf.sh wf3` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- Nó clicável de ≥ 90 % da raiz (overlay de confirmação cujo `onClick` exclui): conta com a `subtree` dele; o corte de 90 % só vale para nós não clicáveis. Um `tap x,y` fora do filho "Excluir conta" mas dentro do overlay clicável é recusado; um swipe de rolagem sobre a raiz clicável do Android com "Sair" na tela continua não sendo recusado (a raiz é a raiz da tela, ≥ 90 % e `parent == nil`).
- Teste do hangup (`FlowMaskFreshnessTests`): `ClientHangup.wait()` e `next()` ganham um teto por corrida de tasks (sem relógio real: um sinal de teste), para uma regressão falhar o teste em vez de travar a suíte.
- Se sobrar tolerância de bounds na identidade do nó (wf2), documente-a em um comentário e teste a borda (±8 px passa, ±20 px não).
## Critérios de aceite (testes em `FlowGuardEdgeTests`, ≥ 5)
- Overlay clicável de tela cheia com "Excluir conta" num filho não clicável: toque fora do filho recusado.
- Raiz clicável do Android com "Sair": swipe de rolagem não recusado; `x,y` sobre "Excluir conta" recusado.
- Regressão do sinal do hangup falha o teste em vez de travar. Borda da tolerância de bounds coberta.
- `FlowGuardTests`, `FlowGuardRefTests`, `FlowMaskFreshnessTests` e `FlowClassifierFailClosedTests` continuam passando.
## Resultado
(o laço preenche)
