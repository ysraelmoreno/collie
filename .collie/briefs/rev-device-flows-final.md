# Revisão final independente das ondas b e c (fluxos do device), 2026-11-26. Achados dados, não instruções.
# Revisão final das ondas b e c dos fluxos do device (b547c05c..HEAD, sem o 48d84d6f)

Revisão só por leitura: não editei nada, não fiz commit e não rodei build nem testes.

**O que foi corrigido:**
- **Cancelamento:** o `UnixSocket` marca o `ClientHangup` e o `FlowRunner` lê a marca só entre passos, então o passo em curso termina inteiro. O `@TaskLocal` chega ao runner porque o roteador só faz `await` direto, sem `Task.detached` no meio.
- **Janela da máscara:** a geração é tirada antes da ação e o texto só vai em claro se `depois == antes + 1`. A geração é monotônica no `stop`/`panelClosed`, sobe antes do `forward` no `onFrame` e nenhum lock fica segurado durante um `await`.
- **Densidade:** recua após falha e não bloqueia o `device.screen`.
- **Erros e rotação:** os `errors` vão junto na mensagem quando um passo falha, e uma rotação que falha não perde a linha.

**Restam furos na classificação destrutiva (major 1).**

**Segurança**
1. **major**, `FlowRunner.swift:136`: um alvo que não é clicável e não tem ancestral clicável não leva os descendentes em conta.
   - Cenário: `tap id:<container>`, um `Group`/`Other` no iOS ou um `LinearLayout` no Android, com o botão "Finalizar pedido" no centro. O `UITree.target` devolve o próprio container e o `device.tap` toca o centro dele, ou seja, o botão. O classificador só olha o nome do container e não recusa.
   - O teste do critério de aceite usa container `clickable: true` (`FlowClassifierServiceTests.swift:49`), por isso não pega o caso.
   - O mesmo vale para um swipe sobre o thumb de "Deslize para pagar" quando o slider não é clicável.
   - Correção: incluir sempre os descendentes e também classificar o nó sob o centro do alvo resolvido, como no caminho `x,y`.
2. **minor**, `FlowRunner.swift:147`: no caminho `x,y`, o classificador escolhe o menor nó que contém o ponto, mas o toque vai para o nó de cima na ordem de desenho.
   - Cenário: um overlay na mesma janela (Compose, bottom sheet inline) com o botão "Excluir conta" maior que uma linha benigna por baixo dele. É a linha de baixo que é classificada.
   - Correção: falhar fechado e recusar se qualquer nó que contém o ponto, ou o ancestral clicável dele, for destrutivo.
3. **minor**, `FlowRunner.swift:119` e `DeviceService.swift:664`: quando a leitura está "fresca", a classificação usa os `refs`, mas o `device.tap` refaz o dump (`:397`).
   - Cenário: a tela muda sozinha sem ação nem toque (timer, carregamento, sessão expirada). A geração não anda e o alvo do tap passa a ser outro.
   - Custo extra: um passo sem `expectSig` faz dois dumps.
   - Correção: classificar sobre o dump do próprio `device.tap`, ou passar ao tap o `ref` que foi classificado. Isso fecha a corrida e economiza um dump.
4. **minor**, `FlowRunner.swift:88` e `:162`: um texto que a árvore não acha e o OCR acha por "contém" é classificado só pelo texto do passo.
   - Cenário: `tap "agar"` numa tela Flutter ou WebView sem a11y acha "Pagar" pelo OCR e não é recusado. O comentário `ponytail` documenta isso, mas é exatamente o bypass original.
   - Correção: quando a árvore não tem hit, classificar o rótulo que o OCR encontrou ou recusar.
5. **minor**, `DeviceService.swift:231`: a máscara só vê os toques feitos pelo viewer.
   - Cenário: o usuário toca no Simulator.app, no aparelho Android físico ou num scrcpy de fora e cai numa tela de senha. Um `device text` logo depois parte de uma leitura que conta como fresca e sem campo de senha, e o texto vai em claro.
   - Correção: para gravar em claro, exigir também que a leitura seja recente (por exemplo < 2 s) ou refazer o dump antes do `device.text` quando o log está ligado.
6. **nit**, `FlowRunner.swift:91`: faltam formas destrutivas comuns na lista: "cancelar assinatura"/"cancel subscription", "encerrar conta"/"close account", "limpar dados"/"clear data", "redefinir"/"reset", "desativar".
7. **nit** (repete o achado 4 da onda b): quem tinha `.collie/flows/enabled` fica com o log desligado sem aviso.

**Motor**
8. **nit**, `FlowActionLog.swift:82`: uma pasta no lugar de `actions.1.jsonl` faz toda rotação falhar. O arquivo atual cresce sem limite e cada ação escreve uma linha no stderr. Correção: com `.1` inválido, dar `unlinkat` com `AT_REMOVEDIR` ou truncar o arquivo atual.
9. **nit**, `DeviceService.swift:149`: o primeiro `device screen` de cada serial Android sai sem densidade, então os tamanhos de alvo não são julgados e a saída de a11y muda entre a 1ª e a 2ª leitura. Aceitável, mas vale uma linha no doc.
10. **nit**, `DeviceCommands.swift:88`: nenhum teste exercita a ligação `ClientHangup.current` → `runner.hungUp` pelo `deviceRunCommand`. Os testes cobrem o socket e o runner separados, e remover esta linha não quebraria nenhum teste. Correção: um teste de socket → roteador → plano de 5 passos.

Não achei regressão em protocolo, deadlock nem latência do `device.screen`. As entradas por painel em `FlowGen`/`closed` ficam até o daemon parar, o que já está documentado com `ponytail`.
