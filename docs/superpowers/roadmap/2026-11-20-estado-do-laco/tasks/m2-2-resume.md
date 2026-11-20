# M2.2 Retomar o commit que já existe após queda do daemon

Leia `onda2.md` e `README.md`. Código: `Sources/CollieCore/Work.swift` (`WorkTask`, `WorkLoopState`), `Sources/CollieDaemonKit/Work/WorkLoop.swift` e `AttemptMachine.swift`, `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`stopLoopsLeftRunning`, `workRun`).

## Problema

O `collied` cai (ou é reiniciado pelo app) no meio de uma tentativa. O varredor `stopLoopsLeftRunning` marca o laço como `stopped`, a tarefa volta a `open` e o job vai a `gone`. Se o agente já tinha feito o commit, o próximo `work run` chama **um agente novo** para uma tarefa cujo código já está no branch: trabalho duplicado, ou o agente novo estraga o que estava certo.

## Fazer

1. Ao **iniciar** uma tentativa, o motor grava em `WorkTask.resumeFrom: String?` o `before` (sha do HEAD) e o `branch` (`resumeBranch`), junto do que já grava. Limpa ao fim da tentativa (passou, falhou ou foi cancelada de forma limpa).
2. O varredor, ao reabrir a tarefa interrompida, **mantém** `resumeFrom`/`resumeBranch` e grava `stopReason = daemonRestart` (já existe, M1.1).
3. No próximo `work run`, ao começar a tentativa de uma tarefa com `resumeFrom`: se o worktree está no mesmo `branch`, o HEAD é descendente de `resumeFrom` e **à frente** dele (`committed`), e a árvore rastreada está limpa, a tentativa é uma **adoção**: **não chama agente**; vai direto à medição dos fatos e ao check/gate, com `before = resumeFrom`. Evento novo `adopted` na máquina e no diário. Se passa, a tarefa fecha como `done` com a evidência normal (a tentativa conta como a seguinte, `tries` e `--max`). Se falha, o `discard` volta a árvore para `resumeFrom` como hoje e a próxima tentativa é normal (com agente). Em qualquer outra condição (branch diferente, HEAD não à frente, árvore suja), ignora `resumeFrom`, limpa-o e segue como hoje.
4. Segurança: `resumeFrom` vem do arquivo do trabalho; valide que é um sha hexadecimal de 40 caracteres e que existe no repositório antes de usar (um valor adulterado nunca vira argumento de git sem validação).
5. Compatibilidade: campos opcionais, arquivo antigo decodifica.
6. **Cancelamento de ponta a ponta** (achado 4 da revisão da Onda 1). Hoje `Task.isCancelled` só é olhado depois do turno; se o daemon para (`cancelLoops`) **durante o check, o portão ou a espera por outros terminais**, o erro do `host.check` vira veredito: a tentativa é contada, descartada e, na última, a tarefa é **adiada** por causa de um desligamento. Faça o interpretador checar o cancelamento antes de devolver `checkDone`/`gateDone`/`blocked` e devolver o evento `.cancelled`, que a máquina já trata em qualquer fase: sem veredito, sem `discard`, a tarefa volta a `open` com a tentativa **não contada**, o job `gone`, e a tarefa mantém `resumeFrom` (itens 1 a 3) para ser julgada na retomada.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopResumeTests.swift`

Host falso + repositório temporário (como `WorkLoopTests`): queda simulada (tarefa `open` com `resumeFrom` e um commit novo) → `work run` não chama `summon` e fecha a tarefa quando o check passa; o diário tem `adopted`; check que falha na adoção → discard e depois tentativa normal com agente; branch diferente → ignora e limpa; árvore suja → ignora; `resumeFrom` inválido (não hex, comprimento errado, inexistente) → ignora sem rodar git com ele; tarefa sem `resumeFrom` não muda de comportamento; `stopLoopsLeftRunning` preserva `resumeFrom`. Cancelamento: durante o check, durante o portão e durante `awaitOthers` cada um deixa a tarefa `open`, `used` não incrementado, nada descartado e **nenhuma** tarefa adiada, mesmo na última tentativa.
