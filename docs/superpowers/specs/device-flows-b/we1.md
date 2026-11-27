# we1: o tap toca o que foi classificado (dump no flowDestructive, ref: fail-closed, identidade do nó)

Onda e da revisão da onda d (`.collie/briefs/rev-device-flows-onda-d.md`, achados 1, 2 e 3; leia). Check: `scripts/check-device-flows-we.sh we1` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- Achado 1 (regressão da wd1): para tap por texto ou `id:`, o `flowDestructive` sempre faz **um dump novo** e fixa o `ref` **desse** dump; nunca os `refs` em cache, mesmo com a leitura "fresca" por geração. O dump do próprio tap não se repete: continua um dump por passo. O teste `aScreenThatChangesByItselfIsTappedOnTheRefClassified` hoje dá o comportamento errado como certo: reescreva para provar que o que é tocado é o que foi classificado no dump novo (tela que muda sozinha entre a leitura em cache e o passo).
- Achado 2: o alvo `ref:` passa pelo mesmo tratamento dos outros (`clickable(i) ?? i`, descendentes sempre para o não clicável, mais o nó sob o centro e o ancestral clicável). Um `tap ref:<container não clicável>` com "Finalizar pedido" no centro é recusado.
- Achado 3: o `ref` é posicional e é resolvido de novo na hora do tap; um `device screen` concorrente o troca. Mande ao tap a identidade do nó classificado (classe, texto, id e bounds) junto com o `ref` e **recuse** se o nó que o `ref` resolve agora for outro.
## Critérios de aceite (testes em `FlowTapPinTests`, ≥ 7)
- Tela que muda sozinha entre a leitura em cache e o passo: toca o nó classificado no dump novo, recusa se o novo nó for destrutivo.
- `tap ref:<Group não clicável>` com descendente destrutivo no centro recusado (iOS e Android).
- `device screen` concorrente que regrava os `refs` entre classificar e tocar: o tap é recusado (identidade diferente), não toca o nó errado.
- Um dump por passo (contador no teste). Sem regressão: `FlowClassifierFailClosedTests`, `FlowClassifierServiceTests`, `FlowClassifierTests`, `FlowDestructiveTests` e `FlowRunnerTests` continuam passando.
## Resultado
(o laço preenche)
