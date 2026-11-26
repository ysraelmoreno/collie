# Revisão independente da onda d (fluxos do device), 2026-11-26. Achados dados, não instruções.
Revisão da onda d (`bd822f02..HEAD`), feita só por leitura: não editei nada, não fiz commit e não rodei build nem testes.

**Estado dos achados**
- **Fechados:** 1 (por `id:` e por texto), 2, 4, 6, 5, 7, 8, 9 e 10.
- **Reabertos:** o achado 3 voltou como regressão, e o achado 1 continua aberto pelo caminho `ref:`.

**Achados**

1. **major**, `FlowRunner.swift:134` com `DeviceService.swift:675`: o tap fixado no `ref` toca coordenadas velhas.
   - Quando a leitura conta como fresca pela geração, o `resolve` classifica sobre os `refs` em cache e troca o alvo para `ref:eN`. Com `ref`, o `device.tap` não refaz o dump: no iOS toca o centro guardado (`DeviceService+iOS.swift:84`).
   - Cenário: tela muda sozinha (timer, carregamento). O passo `tap "Voltar"` foi classificado com "Voltar" em (0,0), mas agora é "Pagar" que está lá, e o toque cai em "Pagar".
   - O teste `aScreenThatChangesByItselfIsTappedOnTheRefClassified` (`FlowClassifierFailClosedTests.swift:100`) dá esse comportamento como certo. Antes da onda d, o tap refazia o dump e acharia "Voltar" no lugar novo, então é regressão: o ref classificado é o ref tocado, mas o pixel tocado não é o que foi classificado.
   - Correção: para tap por texto ou `id:`, sempre fazer um dump no `flowDestructive` e fixar o `ref` desse dump. O dump do próprio tap já some, então continua um dump por passo. Outra opção é exigir também `flowReadAt` recente (o mesmo limite `flowReadMaxAge`).
2. **major**, `FlowRunner.swift:204`: o alvo `ref:` ficou fora do fail-closed.
   - O `subtree($0)` só puxa os descendentes quando o nó é clicável. Também não classifica o nó sob o centro nem o ancestral clicável.
   - Cenário: `tap ref:<Group/LinearLayout não clicável>` com "Finalizar pedido" no centro. O `device.tap` no iOS toca o centro e não há recusa. Nos planos o `ref:` é aceito desde b3.
   - Correção: usar no `ref:` o mesmo tratamento de `hits`: `clickable(i) ?? i`, `all: true` para o não clicável, mais `at(centro)`.
3. **minor**, `DeviceService.swift:675` com `:417`: o `ref` fixado é posicional (`e<n>`, `o<n>`) e é resolvido de novo nos `refs` na hora do tap.
   - Cenário: um `device screen` concorrente (outro cliente) entre o `resolve` e o `act` regrava os `refs`, e `e12` passa a ser outro nó.
   - Correção: mandar ao tap as coordenadas e a identidade do nó (cls, texto, id) junto, e recusar se o nó mudou.
4. **minor (falso positivo)**, `FlowRunner.swift:179` e `:184`:
   - Uma raiz clicável (no Android, `clickable=true` no root é comum para engolir toques) leva a tela inteira para qualquer `x,y` ou swipe. Aí todo swipe de rolagem numa tela com "Sair" é recusado.
   - O corte `bounds != nodes[0].bounds` não pega um content view quase do tamanho da tela (raiz com a status bar): um toque numa folha não clicável sob ele herda todos os rótulos da tela.
   - Correção: ignorar ancestrais cuja área seja ≥ ~90% da raiz.
5. **minor**, `FlowMaskFreshnessTests.swift:70` e `:206`: o `until` fica em busy-spin com `Task.yield` e tem um teto de 10 s de relógio real.
   - Num CI carregado, o pool cooperativo disputa CPU com o spin. Se o hangup não chega em 10 s, o teste segue em silêncio e falha na asserção do passo 3, o que pode parecer flaky.
   - Correção: esperar com `AsyncStream` ou uma continuation sinalizada pelo `ClientHangup`, sem polling.
6. **nit**, `DeviceService.swift:845`: o `panelClosed` não limpa o `flowReadAt[id]`. A entrada fica até o daemon parar; é inofensivo por causa do `closed`, mas diverge do `flowFreshAt`.
7. **nit**, `FlowActionLog.swift:174`: com uma pasta não vazia em `.N`, toda rotação falha e o arquivo atual é truncado a cada vez que enche. O histórico se perde em blocos de `maxBytes`, sem rotação, e o aviso não diz isso. A spec aceita truncar; vale citar o truncamento no aviso.

Sem regressão em locks, geração, protocolo nem latência do `device.screen`. O passo deixou de fazer o segundo dump.
