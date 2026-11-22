# M13.3 O laço não deixa a tentativa mexer no `collie-work.json` e lê o arquivo da base

Leia `onda13.md` e, no motor, o guard do portão (`WorkLoop.tampered`, `AttemptMachine`; memória "guard barra tarefa que deve mudar o portão"). O `collie-work.json` é conteúdo do repositório: se o agente pudesse reescrevê-lo, escolheria o próprio check e o próprio portão.

## Fazer
1. **Base, não árvore:** quando o laço roda (`work run`), o `gate`/`precheck` do arquivo (M13.2) são lidos da **versão commitada da base** (`git show <HEAD no início do laço>:collie-work.json`, com `--literal-pathspecs`/`--`), nunca da árvore de trabalho. Arquivo ausente na base = os padrões de hoje.
2. **Tamper:** uma tentativa cujo diff (base da tentativa → o que ela commitou/deixou) altera `collie-work.json` **reprova** com o motivo "alterou collie-work.json" (mesmo caminho do guard de script do portão; a spec da tarefa que cita o arquivo literalmente o libera, como já acontece com o guard do portão).
3. As tarefas já criadas com `--area` guardam o check montado (M13.2): editar o arquivo depois não muda o check de uma tarefa já criada.

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/WorkConfigTamperTests.swift`
O laço usa o `gate` da base mesmo com o arquivo da árvore diferente (arquivo sujo na árvore, ou commit novo da tentativa); tentativa que edita o arquivo reprova com o motivo certo e a tentativa é descartada como as outras; spec que cita o arquivo libera; arquivo ausente na base = padrões de hoje; tarefa com check montado não muda quando o arquivo muda; `WorkLoopTests` e `AttemptMachineTests` sem adaptação. O fake aplica a regra real (git real em repositório temporário).

## Check
`scripts/check-onda13.sh m13-3`.
