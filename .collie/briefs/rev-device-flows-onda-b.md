# Re-revisão independente da onda b (fluxos do device), 2026-11-26. Achados dados, não instruções.
Os cinco majors da 1ª revisão foram corrigidos no ponto que cada um apontava, mas sobram 2 majors: a classificação destrutiva tem bypass e o cancelamento não funciona em produção. Revisão só por leitura: não editei, não rodei build nem testes.

**Corrigido sem furo novo:**
- `AXeTree` marca `password` e não guarda mais o valor do campo.
- O log abre arquivos por `openat` com `O_NOFOLLOW|O_NONBLOCK` e exige arquivo regular com `nlink==1`. Um FIFO dá ENXIO ou é recusado pelo `fstat`.
- Chave desconhecida no passo é rejeitada.
- `settle: stable` vai junto no próprio passo.
- A densidade com falha não fica mais em cache.

**Segurança**
1. **major**, `FlowRunner.swift:125` e `:110-122`: a classificação usa os nós da última leitura, mas o `device.tap` refaz o dump e escolhe o alvo de outro jeito (`DeviceService.swift:351-353`). São dois bypasses:
   - `tap "agar"` acha "Pagar" por contém e sobe ao ancestral clicável. Num Android típico o ancestral é um container sem rótulo, então só "agar" e o id do container são checados e nada é recusado, mesmo com leitura fresca.
   - Um plano sem `expectSig` (`tap "Carrinho"` e depois `tap 540,1800` ou `tap id:<id opaco>`) é classificado contra a tela anterior.
   - Correção: classificar dentro do `DeviceService` depois de resolver o alvo, sobre o nó a tocar e seus descendentes, e para `x,y` fazer um dump antes.
2. **minor**, `FlowRunner.swift:89` e `:110`: só taps são classificados. `key Enter`, `text "…\n"` e swipe de "deslize para pagar" passam. A lista também perde formas comuns: "Pague", "Pagamento", "Confirmar" sozinho, "Sair", "Concluir", "Transferir", "Enviar", "Submit", "Order".
3. **minor**, `DeviceService.swift:717` e `:207`: a máscara ainda pode falhar aberta em duas corridas. Em ambas, o texto digitado vai em claro.
   - O `flowStale` roda numa Task sem ordem. Um toque do viewer no campo de senha seguido de `device text` pode ser atendido antes do `flowStale`. O comentário "a late one only over-masks" está errado.
   - Uma leitura em voo durante um toque marca a tela como fresca com `refs` velhos.
   - Correção: um contador de geração atualizado de forma síncrona (lock) em `onInput` e nas ações. Só marcar fresca se a geração não mudou durante a leitura.
4. **nit**, `DeviceCommands.swift:95`: o opt-in em `<root>/flows/<id>/enabled` só está protegido se o sandbox de SO impedir o agente de escrever em `root`. Com o mesmo uid e sem sandbox, `touch` continua ligando o log. Também: quem tinha `.collie/flows/enabled` fica desligado sem aviso.

**Motor/concorrência**
5. **major**, `FlowRunner.swift:165`: o cancelamento nunca dispara em produção. `UnixSocket.swift` só cancela `work.wait` quando o cliente desliga (`cancelsOnHangup`), e `device.run` roda num `Task.detached` que ninguém cancela. Um plano de 200 passos continua tocando depois do ctrl-C. O teste passa porque cancela a própria Task.
   - Correção: tratar o hangup de `device.run` com uma flag lida entre passos, sem cancelar o passo em curso. Se cancelar o `act` direto, um tap com `then: screen` fica pela metade.
6. **minor**, `FlowRunner.swift:175-177`: quando um passo falha, a exceção descarta os `errors` já juntados. É o caso do crash no passo 2 que faz o passo 3 dar "not found", justamente o erro que explica a falha. Correção: anexar os `errors` à mensagem ou ao payload.
7. **minor**, `DeviceService.swift:122` e `:244`: enquanto `wm density` dá timeout, cada `device screen` do Android, e cada passo com `expectSig`, espera até 5 s em série. Antes isso acontecia uma vez só. Correção: cache negativo com backoff (~30 s) ou ler a densidade fora do caminho da tela.
8. **minor**, `FlowActionLog.swift:78` e `:104-109`: se a rotação falha depois dos `renameat` (tmp ocupado por uma pasta, ENOSPC), `append` lança a exceção antes de reabrir o arquivo atual e a linha nova se perde. Correção: capturar o erro da rotação, logar em stderr e escrever mesmo assim.
9. **nit**, `DeviceService.swift:717`: cria uma Task por frame de entrada, inclusive os toques em movimento do Android a ~60 Hz. Basta marcar a tela gasta só no toque de descida.
