# wf1: a classificação destrutiva roda dentro do `device.tap`/`device.swipe`, sobre o nó que ele mesmo resolveu

Onda f (opção B da conferência da onda e, `.collie/briefs/rev-device-flows-onda-e.md`; leia, e `rev-device-flows-onda-d.md`). A classe de bug das ondas c, d e e é uma só: *o que foi classificado não é o que é tocado* (cache, `pin`, fallback para o centro velho). Aqui ela se fecha na raiz: a classificação e o toque usam **a mesma leitura**, dentro do mesmo comando. Check: `scripts/check-device-flows-wf.sh wf1` (não o altere). Sem relógio real nem sleep; só `swift test --filter`.

## O que construir
- `device.tap` e `device.swipe` aceitam um argumento `guard: "destructive"` (só o `FlowRunner` o manda, em todo passo `tap`/`swipe` de um plano **sem** `--confirm-destructive`; o passo marcado `destructive: true` pelo autor continua recusado como hoje). Não existe flag de CLI para um agente desligar o guard de um plano.
- Com `guard`, o comando resolve o alvo **na sua própria leitura de tela** (a que ele já faz para achar o nó: helper/uiautomator no Android, árvore do AXe no iOS, OCR como fallback), classifica **esse nó** com as regras do `FlowClassifier` (rótulos do nó, descendentes se não clicável, nó sob o centro, ancestral clicável, todos os nós sob `x,y`, corte de 90 % da raiz) e, se for destrutivo, **recusa antes de tocar** com um erro de protocolo identificável (código novo ou mensagem com o prefixo fixo `destructive:`; o runner o converte em `{refused:"destructive", at, done}`).
- **Fail-closed:** se o comando não consegue ler a tela para classificar, ou se o nó que ele ia tocar vem de outra leitura que não a da classificação (fallback para o centro de um nó velho, `m.path == nil`, `m` não achado), ele **recusa** (`.conflict`), nunca toca no centro antigo. Isso vale nos dois backends (`DeviceService+Android.swift` e `DeviceService+iOS.swift`).
- Texto que só o OCR acha: classifica o rótulo que o OCR leu; OCR sem rótulo recusa.
- `FlowClassifier` continua dono das regras (lista, subárvores, corte); só muda **onde** é chamado e **sobre quais nós** (os da leitura do tap).
## Critérios de aceite (testes em `FlowGuardTests`, ≥ 10; testes que passam pelo `DeviceService` real com `Device` falso nos dois backends, não só pelo `FlowRunner`)
- Android e iOS: `tap "Pagar"` com guard recusa e não toca; `tap "Voltar"` toca.
- Tela que muda entre a classificação "antiga" e o toque: o que é classificado é o que é tocado (a leitura é a do tap), em texto, `id:` e `x,y`.
- Android: caminho do helper velho e leitura nova sem o nó: recusa com `.conflict`, não toca o centro velho. `m` achado com `m.path == nil`: não toca o centro antigo.
- Swipe com guard sobre thumb "Deslize para pagar" em slider não clicável recusa.
- OCR com rótulo destrutivo recusa; OCR sem rótulo recusa.
- Sem guard (uso normal de `device tap`), nada muda.
- `FlowClassifierTests`, `FlowClassifierServiceTests`, `FlowClassifierFailClosedTests`, `FlowDestructiveTests`, `FlowRunnerTests` e `FlowTapPinTests` continuam passando nesta tarefa (a limpeza do `pin` é a wf2).
## Resultado
(o laço preenche)
