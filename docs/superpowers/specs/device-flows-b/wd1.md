# wd1: classificação destrutiva fail-closed

Onda d da revisão final (`.collie/briefs/rev-device-flows-final.md`, achados de segurança 1, 2, 3, 4 e 6; leia). Check: `scripts/check-device-flows-wd.sh wd1` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- Alvo não clicável e sem ancestral clicável (container `Group`/`Other`/`LinearLayout`): a classificação **sempre** inclui os descendentes e também o nó sob o **centro** do alvo resolvido (é onde o `device.tap` toca). Vale para tap e swipe (thumb de "Deslize para pagar").
- Caminho `x,y`: **fail-closed**. Se qualquer nó que contém o ponto, ou o ancestral clicável dele, for destrutivo, recusa (não só o menor nó).
- Classificar sobre o **mesmo alvo** que o `device.tap` vai tocar: ou a classificação roda sobre o dump do próprio tap, ou o `ref` classificado é passado ao tap. Sem segundo dump à toa e sem corrida com tela que muda sozinha.
- Texto que a árvore não acha e o OCR acha por "contém": classificar o rótulo que o OCR encontrou; sem rótulo, recusar.
- Lista ampliada (constante testável, sem caixa e sem acento): cancelar assinatura, cancel subscription, encerrar conta, close account, limpar dados, clear data, redefinir, reset, desativar, deactivate.
## Critérios de aceite (testes em `FlowClassifierFailClosedTests`, ≥ 8)
- `tap id:<container não clicável>` com descendente "Finalizar pedido" no centro é recusado (iOS e Android).
- Swipe sobre thumb de "Deslize para pagar" em slider não clicável é recusado.
- `x,y` onde o menor nó é benigno mas um overlay maior que contém o ponto é "Excluir conta": recusado.
- Tela que muda entre a leitura e o toque: o que foi classificado é o que é tocado (verificar o `ref`/dump usado).
- Texto só do OCR com rótulo destrutivo recusado; sem rótulo recusado. Formas novas da lista recusadas. "Voltar" não.
- `FlowClassifierServiceTests`, `FlowClassifierTests`, `FlowDestructiveTests` e `FlowRunnerTests` continuam passando.
## Resultado
(o laço preenche)
