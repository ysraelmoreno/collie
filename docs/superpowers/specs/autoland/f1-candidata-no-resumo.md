# F1 (mecanismo): armadilha candidata no resumo do trabalho

Roadmap F1, 3º item. NÃO converte nada sozinho e NÃO mexe em escala (a triagem com o dono fica para depois de 2026-12-02, fim da medição da memória).

## O que fazer
Ao fechar o laço (`WorkLoop` fim, onde o resumo é montado), se a MESMA falha apareceu em 2 ou mais tentativas do trabalho (mesma tarefa ou tarefas diferentes) — mesma assinatura: o mesmo `check`/`gate` falhando com a mesma primeira linha de erro normalizada (sem números, caminhos de worktree e tempos), ou o mesmo motivo de veto (persona + arquivo) — o resumo do trabalho ganha uma seção "Armadilhas candidatas" com: a assinatura, quantas vezes, em quais tarefas, e o comando pronto para o dono decidir (`collie memory save ... --trap` ou o equivalente atual de armadilha; veja `collie memory --help`). Nada é gravado em memória; só texto no resumo.
Limites: no máximo 5 candidatas; texto limpo pelo `scrub`; nada de saída crua do agente (use as linhas já limpas). Sem falha repetida: nenhuma seção.

## Testes
Assinatura normaliza números e caminhos; duas falhas iguais viram candidata; falhas distintas não; limite de 5; scrub; sem repetição = sem seção. Suíte `TrapCandidateTests` em `Tests/CollieDaemonKitTests`.

Check: `scripts/check-autoland-loop.sh f1`. Commit ao final, só os arquivos da tarefa.
