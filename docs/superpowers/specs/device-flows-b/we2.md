# we2: falsos positivos da raiz clicável, teste sem busy-spin e aviso da rotação

Onda e da revisão da onda d (`.collie/briefs/rev-device-flows-onda-d.md`, achados 4, 5, 6 e 7). Check: `scripts/check-device-flows-we.sh we2` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- Achado 4: ancestral cuja área é ≥ ~90 % da raiz (raiz clicável do Android, content view quase do tamanho da tela) **não** conta para classificar `x,y`/swipe/toque em folha. Um swipe de rolagem numa tela com "Sair" não é recusado; um toque em "Excluir conta" de verdade continua recusado.
- Achado 5: os testes do hangup (`FlowMaskFreshnessTests`) esperam por `AsyncStream` ou continuation sinalizada pelo `ClientHangup`, sem polling com `Task.yield` nem teto de relógio real de 10 s.
- Achado 6: `panelClosed` limpa também `flowReadAt[id]`.
- Achado 7: com pasta não vazia em `.N`, o aviso da rotação diz que o histórico foi truncado.
## Critérios de aceite (testes em `FlowRootFalsePositiveTests`, ≥ 5)
- Swipe de rolagem com raiz clicável e "Sair" na tela não é recusado; `x,y` sobre "Excluir conta" com a mesma raiz é recusado.
- Content view de ~95 % da área não herda os rótulos para um toque em folha.
- `panelClosed` remove `flowReadAt`. O aviso da rotação cita o truncamento.
- `FlowMaskFreshnessTests`, `FlowTapPinTests` e `FlowClassifierFailClosedTests` continuam passando.
## Resultado
(o laço preenche)
