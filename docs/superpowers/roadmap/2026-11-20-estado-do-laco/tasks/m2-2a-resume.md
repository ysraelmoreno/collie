# M2.2a Retomar o commit que já existe após queda do daemon (parte 1 de 2 da M2.2 original)

Leia `onda2.md` e `README.md`. Código: `Sources/CollieCore/Work.swift` (`WorkTask`, `WorkLoopState`), `Sources/CollieDaemonKit/Work/WorkLoop.swift` e `AttemptMachine.swift`, `Sources/CollieDaemonKit/WorkLoopCommands.swift` (`stopLoopsLeftRunning`, `workRun`).

## Problema

O `collied` cai (ou é reiniciado pelo app) no meio de uma tentativa. O varredor `stopLoopsLeftRunning` marca o laço como `stopped`, a tarefa volta a `open` e o job vai a `gone`. Se o agente já tinha feito o commit, o próximo `work run` chama **um agente novo** para uma tarefa cujo código já está no branch: trabalho duplicado, ou o agente novo estraga o que estava certo.

> **Por que dividida:** a M2.2 única foi adiada em 3 tentativas (o check falhou com 3 testes, nomes desconhecidos porque o laço guarda só o rabo da saída). A parte 1 é só a retomada (itens 1 a 5); o cancelamento de ponta a ponta é a M2.2b. Rode as suítes da família **uma de cada vez** durante o desenvolvimento e leia os nomes dos testes que falham.

## Fazer

1. Ao **iniciar** uma tentativa, o motor grava em `WorkTask.resumeFrom: String?` o `before` (sha do HEAD) e o `branch` (`resumeBranch`), junto do que já grava. Limpa ao fim da tentativa (passou, falhou ou foi cancelada de forma limpa).
2. O varredor, ao reabrir a tarefa interrompida, **mantém** `resumeFrom`/`resumeBranch` e grava `stopReason = daemonRestart` (já existe, M1.1).
3. No próximo `work run`, ao começar a tentativa de uma tarefa com `resumeFrom`: se o worktree está no mesmo `branch`, o HEAD é descendente de `resumeFrom` e **à frente** dele (`committed`), e a árvore rastreada está limpa, a tentativa é uma **adoção**: **não chama agente**; vai direto à medição dos fatos e ao check/gate, com `before = resumeFrom`. Evento novo `adopted` na máquina e no diário. Se passa, a tarefa fecha como `done` com a evidência normal (a tentativa conta como a seguinte, `tries` e `--max`). Se falha, o `discard` volta a árvore para `resumeFrom` como hoje e a próxima tentativa é normal (com agente). Em qualquer outra condição (branch diferente, HEAD não à frente, árvore suja), ignora `resumeFrom`, limpa-o e segue como hoje.
4. Segurança: `resumeFrom` vem do arquivo do trabalho; valide que é um sha hexadecimal de 40 caracteres e que existe no repositório antes de usar (um valor adulterado nunca vira argumento de git sem validação).
5. Compatibilidade: campos opcionais, arquivo antigo decodifica.

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/LoopResumeTests.swift`

Host falso + repositório temporário (como `WorkLoopTests`): queda simulada (tarefa `open` com `resumeFrom` e um commit novo) → `work run` não chama `summon` e fecha a tarefa quando o check passa; o diário tem `adopted`; check que falha na adoção → discard e depois tentativa normal com agente; branch diferente → ignora e limpa; árvore suja → ignora; `resumeFrom` inválido (não hex, comprimento errado, inexistente) → ignora sem rodar git com ele; tarefa sem `resumeFrom` não muda de comportamento; `stopLoopsLeftRunning` preserva `resumeFrom`.
