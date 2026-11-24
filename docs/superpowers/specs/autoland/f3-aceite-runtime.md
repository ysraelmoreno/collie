# F3: aceite em runtime (`work task add --accept`), a 4ª condição

Roadmap: `docs/superpowers/roadmap/2026-11-22-fabrica/README.md` (F3) e `2026-11-24-autoland/README.md`. O check de uma tarefa julga o código; o aceite julga o RESULTADO rodando (a tela abre, o serviço responde, o fluxo passa). Sem framework novo: é um comando de shell com a mesma regra de isolamento do check.

## Comportamento
1. `work task add ... --accept "<comando>"` (CLI e MCP `work_task_add`): guarda o comando NO ESTADO DO TRABALHO (como `check`), aprovado com a tarefa pelo dono. O agente não vê nem altera esse campo; o laço lê do estado, nunca da worktree. Mesmo limite de caracteres e a mesma validação do `check` (sem comando vazio, sem controle).
2. Ordem na tentativa: check → gate → **aceite** → parecer (revisão). O aceite roda onde o check roda (worktree da tentativa, sob o mesmo perfil de sandbox e timeout do check; padrão 600 s, `--accept-timeout` por tarefa até 1800), DEPOIS que o agente terminou o turno e foi dispensado, para que nada que o agente deixou rodando o atenda. Não rodar o aceite se o check ou o gate falharam.
3. Falha do aceite = falha de check: a tentativa conta, a saída INTEIRA (limitada a 64 KB, limpa pelo scrub do laço, cabeça e rabo) vai para a evidência e para a nota (armadilha "check que mostra só o rabo"). O diário grava `acceptFailed`.
4. Tampering: se o agente alterou arquivos que o comando de aceite cita (mesma regra da `tampered` do gate: subcadeia, só configs puras), a tentativa é reprovada como no gate.
5. Auto-land (A4): o aceite passa a ser a 4ª condição de land. Se QUALQUER tarefa do trabalho tem `--accept`, o land exige que o último aceite dela tenha passado na tentativa vencedora (`landAcceptRed` como `stopReason` se não). Trabalho sem nenhuma tarefa com `--accept` segue como hoje, e o resumo (A6) diz "sem aceite em runtime".
6. `work status`/cartão/`work task` mostram o comando de aceite e o último resultado. Preferência do doctor: `factory.verification.scenarios` continua vazio como aviso; documente em `docs/fabrica` como escrever um aceite com `collie device`/navegador/serviço de app do cercado (exemplos, não framework).

## Testes (`Tests/CollieDaemonKitTests`, hosts falsos; sem terminais reais nem `sandbox-exec`)
Armazenamento e validação do campo; ordem (aceite não roda com check/gate vermelho); falha do aceite reprova a tentativa e guarda a saída inteira (até o limite); o agente não altera o comando (estado vs worktree); `landAcceptRed`; trabalho sem aceite não muda de comportamento. Suíte nova: `AcceptTests`.

Check: `scripts/check-autoland-loop.sh f3`. Commit ao final, só os arquivos da tarefa.
