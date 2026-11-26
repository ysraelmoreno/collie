# Conferência final da onda e (fluxos do device), 2026-11-26. Achados dados, não instruções.
Conferência da onda e (we1 `5fe7a08e`, we2 `bae8668f`), só Devices/Flow e os testes. Foi somente leitura: não editei nada, não fiz commit e não rodei build nem testes.

**Os três achados da onda d**
- **Achado 1 (major), fechado para tap por texto e por `id:`:** o `resolve` faz um dump novo e fixa o `ref` e o `pin` desse dump. O tap não lê de novo, então fica um dump por passo.
- **Achado 2 (major), fechado:** o `ref:` passa por `clickable(i) ?? i`, com `all:` para o não clicável e mais `at(centro)` (`FlowRunner.swift:232`). Um `ref:` sem nó é recusado (`:139`).
- **Achado 3 (minor), fechado:** o `checkPin` compara cls, texto, desc, id e bounds no iOS (`DeviceService+iOS.swift:88`) e no Android (`:176` e `:185`). O `pin` está fora dos `CodingKeys`, então um arquivo de plano não consegue injetá-lo.

**Pontos que você pediu para checar**
- "Excluir conta" com a raiz clicável de 90%: continua recusado. O `screen($0)` só tira os rótulos herdados; os do próprio nó ficam.
- Teste do hangup: sem busy-spin, usa `ClientHangup.wait()` por continuation.

**Achados novos**

1. **major**, `DeviceService+Android.swift:184-191`: o fallback do tap por `ref` toca o centro velho mesmo com `pin`.
   - Cenário: o caminho do helper ficou velho (a tela mudou depois do dump de classificação). A leitura nova não acha o nó (cls, texto, desc, id) e cai em `tapAt(n.center)`, o pixel onde agora está "Pagar". É a mesma classe do achado 1, só que pelo Android.
   - Variante: `m` é achado mas `m.path == nil`; o `n` não é trocado e o toque vai no centro antigo.
   - Correção: com `args["pin"]` presente, se a leitura nova não tem nó com a mesma `identity`, lançar `.conflict`. Quando `m` existe, tocar `m.center`.
   - Os testes não cobrem isso: o `FlowTapPinTests` usa um `Device` falso e não exercita o `DeviceService+Android`.
2. **major (resto do achado 1)**, `FlowRunner.swift:139-142`: um `ref:` escrito no plano é classificado nos `refs` em cache, sem dump, e no iOS o tap usa o centro guardado.
   - Cenário: o plano tem `tap ref:e5` ("Voltar"); a tela avança sozinha (timer ou carregamento) e "Pagar" fica nessa posição. A classificação dá "Voltar", o `pin` bate com o cache e o toque cai em "Pagar".
   - A spec we1 só pediu dump novo para texto e `id:`, mas o `ref:` é aceito nos planos desde b3.
   - Correção: no `ref:`, fazer também o dump e exigir que o nó desse `ref` no dump novo tenha a mesma `identity` do cache; senão, recusar. Continua um dump por passo.
3. **minor**, `FlowRunner.swift:201` e `:207`: um nó clicável de ≥90% da raiz conta só pelos próprios nomes.
   - Cenário: um container clicável de tela cheia (overlay de confirmação, `onClick` = excluir) com "Excluir conta" num filho não clicável. Um `tap x,y` fora do filho cai só em `names(overlay)`, que está vazio, e o toque passa.
   - O comentário `ponytail:` admite esse limite. Correção: quando o nó for de tela e clicável, incluir a `subtree` dele; o corte de 90% vale só para os não clicáveis.
4. **nit**, `FlowMaskFreshnessTests.swift:198` e `:221`: o `wait()` e o `it.next()` não têm teto nenhum. Uma regressão no sinal do hangup trava a suíte em vez de falhar o teste. Correção: um `withTimeout` em clock de teste, ou uma task de corrida que falha o teste.
5. **nit**, `DeviceService+Android.swift:185`: o `pin` inclui bounds, e a leitura nova vem do `helperDump`, que pode não ser a mesma fonte do dump de classificação (uiautomator ou helper). Se os bounds diferirem por um pixel, o tap legítimo é recusado com `conflict` (fail-closed, mas falso). Correção: tolerar uma diferença pequena nos bounds ou comparar o centro.

Sem regressão vista em `flowReadAt`, no `panelClosed`/`stop` nem no aviso de rotação do `FlowActionLog`.
