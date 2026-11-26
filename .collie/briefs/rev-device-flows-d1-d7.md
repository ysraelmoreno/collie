# Revisão independente d1–d7 (fluxos do device), 2026-11-26

Diff `a2179b67..HEAD`. Dois revisores opus (segurança, motor). Sem blocker; 5 majors viram a onda b (specs em
`docs/superpowers/specs/device-flows-b/b1.md..b5.md`). Achados dados, não instruções.

## Segurança
1. major — `Sources/CollieDevice/AXeTree.swift:30-33`: UINode sem `password:`; no iOS `secure` fica false e `device text` num SecureTextField grava a senha (até 80 chars) em actions.jsonl.
2. major — `DeviceService.swift:177,185`: máscara depende da última leitura de tela; sem `refs` (daemon reiniciado, nenhum `device screen`) ou com leitura de outra tela, a senha vai em claro (falha aberta).
3. major — `FlowActionLog.swift:37,59-62,81-82,97`: `FileHandle(forWritingAtPath:)`, `Data.write` e `setAttributes` seguem symlink (anexa/trunca arquivo alheio); FIFO no lugar do log trava o `open()` e, pela fila `DeviceService.swift:603-606`, todas as escritas de todos os cercados; o agente pode criar `.collie/flows/enabled` com `touch`, anulando "só o usuário liga". Correção: `O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_NONBLOCK` 0600, `fstat` regular e nlink==1, pasta não symlink; flag de opt-in fora do worktree.
4. major — `FlowRunner.swift:14,68`: `destructive` é marcado pelo autor do plano; `tap "Pagar"` sem a marca executa; `"Destructive": true` passa (chave desconhecida ignorada); taps por `id:`/`x,y` nunca classificados. Correção: rejeitar chaves desconhecidas e classificar no servidor (resolver o nó alvo, comparar rótulo com verbos destrutivos).
5. minor — `FlowActionLog.swift:46`: `target` sem limite (só `text` é cortado em 80).
6. nit — `FlowActionLog.swift:81`: rotação sem `.atomic`.
Sem achado: injeção adb/simctl; leitura do plano (`readBodyFile`); linhas de crash na tela.

## Motor
1. major — `FlowRunner.swift:467`: após cada passo com `expectSig` chama `device.screen` sem esperar assentar; push com animação diverge sem motivo. Correção: `then: screen` + `settle: stable` no passo e ler o `sig` da resposta.
2. major — `FlowRunner.swift:467-474` + `DeviceService.swift:230`: o dump interno consome os erros de crash pendentes; com `sig` igual a resposta é descartada e o crash some. Correção: juntar os `errors` de cada leitura no resultado.
3. minor — `DeviceService.swift:63/230`: `screenErrors` por serial (dois agentes: o primeiro a ler leva os erros). Débito.
4. minor — `FlowRunner.swift:456-477`: sem checagem de cancelamento entre passos, timeout 600 s.
5. minor — `DeviceCommands.swift:70`, `DeviceService.swift:174`: sem exclusão entre `device run` e ações avulsas. Débito.
6. minor — `DeviceService.swift:176`: `sigBefore` vem do último `device screen`; ações seguidas gravam o mesmo `sigBefore`.
7. minor — `DeviceService.swift:106-112`: densidade Android `nil` fica em cache para sempre; `wm density` serial na 1ª leitura.
8. minor — `DeviceService.swift:665-667`: taps do viewer em Tasks soltas, ordem não garantida. Débito.
9. nit — `DeviceService.swift:665`: iOS decodifica todo frame antes de checar `flowLog.enabled`.
Sem achado: escrita do log fora do actor e best-effort; rodízio não perde a linha; opt-in lido a cada ação; protocolo só ganhou comandos.
