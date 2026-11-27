# wf2: `ref:` sob guard relê a tela e confere a identidade; remover o `pin`, o pré-dump e o cache

Onda f, depende da wf1 (`.collie/briefs/rev-device-flows-onda-e.md`, achado 2; leia). Check: `scripts/check-device-flows-wf.sh wf2` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- `tap ref:eN` com `guard` (um `ref:` escrito num plano ou vindo do passo anterior): o comando **relê a tela**, exige que o nó do `ref` do plano tenha ainda uma `identity` equivalente na leitura nova (classe, texto, descrição, id; bounds ou centro com tolerância pequena e nomeada, ~8 px, para o `uiautomator` e o helper não divergirem de 1 px), toca **o nó da leitura nova** (centro novo) e classifica **esse** nó. Sem equivalente na leitura nova: `.conflict` (a tela mudou), sem tocar.
- Remover o que a wf1 tornou desnecessário: o campo `pin` do `FlowPlan.Step`, `checkPin`, o pré-dump de `flowDestructive` (`DeviceService.flowDestructive`) e o `FlowClassifier.resolve` que fixa `ref:`; o `FlowRunner` só passa `guard` e trata a recusa. **Um dump por passo** (o do próprio comando). Remova os testes que só fixavam o `pin` (`FlowTapPinTests`, `aScreenThatChangesByItself…`) trocando-os pelos novos; o número de testes das suítes de classificação pode cair, mas cada comportamento continua coberto pelos testes da wf1/wf2.
## Critérios de aceite (testes em `FlowGuardRefTests`, ≥ 7)
- `tap ref:e5` ("Voltar") com a tela que avançou sozinha e "Pagar" no lugar: recusa ou `.conflict`, nunca toca "Pagar".
- `ref:` cujo nó segue igual (mesma identity, bounds ±1 px): toca o centro **novo**.
- `ref:` de container não clicável com "Finalizar pedido" no centro: recusa.
- Um dump por passo (contador no `Device` falso). `FlowStep` não tem mais `pin`; um plano em arquivo com `"pin"` é chave desconhecida e é rejeitado.
- `FlowGuardTests`, `FlowClassifierTests`, `FlowDestructiveTests` e `FlowRunnerTests` continuam passando.
## Resultado
(o laço preenche)
