# B6.1 Confiar em laços por cercado: o daemon

Decisão do dono (2026-11-19): ele não quer aprovar o cartão de todo laço; pedir um laço, ou dar o comando, já é permissão. A saída acordada: **confiar por cercado**. O primeiro laço de um cercado ainda mostra o cartão, com "Sempre neste cercado"; nos seguintes, nesse cercado, o laço começa sem cartão e o Pastor recebe só um aviso.

Código: `Sources/CollieCore/Workspace.swift` (`Paddock`), `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`work.run`, o cartão, `startLoop`).

## Fazer

1. `Paddock.trustLoops: Bool?` (opcional, decodifica registro antigo; persiste com o workspace). Some junto com o cercado quando ele é removido.
2. Em `work.run`: com `paddock.trustLoops == true`, **não** cria o cartão: segue direto para `startLoop`. Continuam valendo, sem exceção, tudo o que o cartão protege: `--max` obrigatório, `--tries`, `--timeout`, `--budget` com os tetos de hoje, o sandbox estrito do laço, a recusa se há outro terminal ocupado no cercado, a árvore limpa, e o limite de tamanho do texto das tarefas e checks (o mesmo `loopCardText` é calculado só para validar o tamanho e para o aviso).
3. O Pastor recebe uma linha (`asks.inject`, sem esperar: uma Task solta, como o aviso por tarefa): "[collie] Laço iniciado sem cartão (cercado «X» é confiável): N tarefas, --max M, orçamento B s. Parar: collie work stop." Mais uma linha por tarefa com título e check, cortada pelo mesmo limite de `RerailText.limit`.
4. Um comando admin (só o app): `admin.paddock.trust-loops` com `paddock` (id) e `on` (bool) liga e desliga. Resposta com o estado. O `collie paddock status` mostra "laços sem cartão: sim" quando ligado.
5. Nenhum comando de agente liga a confiança (nem o Pastor, nem o `work.run`): só o app.

## Testes (escrever antes) — `WorkLoopCommandTests`

Cercado não confiável: o cartão é criado e nada roda antes de Permitir (como hoje). Confiável: sem cartão, o laço começa, o Pastor recebe o aviso, `--max` ausente continua recusado, árvore suja continua recusada, outro terminal ocupado continua recusado. Um agente chamando `admin.paddock.trust-loops`: recusado. Registro antigo sem o campo decodifica.

---
Regras do repo: testes só com `swift test --disable-sandbox --filter <Suite> --skip MemoryEventEmissionTests`, nunca a suíte inteira. Sem dependência nova. Textos que o dono vê em português. Commits convencionais; nada de push. Não tocar em scripts/ci/ nem em architecture-rules.txt. O app (CollieApp) só compila e é verificado à mão pelo dono: não rode o app.
