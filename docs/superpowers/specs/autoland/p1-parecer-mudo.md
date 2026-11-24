# P1: o parecer mudo registra a causa e tenta de novo uma vez

Achado de 2026-11-24: nos laços F3, R2 e A2 os 4 revisores ficaram "sem resposta" de uma vez (na A2, tarefa de segurança, não houve parecer algum); na A1 funcionaram. `WorkLoopReview.mute` (`Sources/CollieDaemonKit/Work/WorkLoopReview.swift` ~485)
agrega quatro causas num texto só ("summon recusado, terminal sumiu, passou do tempo do turno, texto vazio") e NÃO guarda qual foi. A hipótese da entrada de trust do `~/.claude.json` sumindo foi testada e descartada (a entrada estava presente).
Sem a causa não dá para corrigir a origem: o objetivo desta tarefa é tornar a falha DIAGNOSTICÁVEL e menos frequente, sem mudar a semântica do parecer.

1. Um tipo pequeno de causa (por exemplo `ReviewMuteCause`: `summonRefused(String)`, `terminalGone`, `timedOut(seconds)`, `emptyText`, `unparsable`) que `mute` carrega; o texto do parecer passa a ser "revisor X sem resposta (causa: ...)" e a causa vai para o diário de eventos do laço
   (`work status --events`) e para o resumo. Uma causa nunca contém texto livre do revisor sem passar pela limpeza que o resto do laço já usa.
2. Se TODAS as personas de uma tentativa ficam mudas, o laço repete a revisão inteira UMA vez (revisores novos, pasta nova), dentro do orçamento do laço, antes de declarar "sem parecer"; se só algumas ficam mudas, não repete (nota por persona, como hoje). A repetição aparece no diário.
3. Semântica intocada: revisor mudo nunca aprova nem veta; "sem parecer" continua só nota. Não mude o isolamento (pasta, sandbox strict, trust) nem o `plantedConfig`.
4. Testes com os hosts falsos de `WorkLoopReviewTests` (sem terminais reais, sem `sandbox-exec`): cada causa aparece no texto e no diário; todas mudas repete uma vez e, se a repetição responde, o parecer vale; todas mudas de novo vira "sem parecer" com as duas causas; só uma muda não repete.

Check: `scripts/check-autoland-loop.sh p1`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
