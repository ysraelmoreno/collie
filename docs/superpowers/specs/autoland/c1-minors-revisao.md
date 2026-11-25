# C1: minors da revisão independente de B1, P1 e P2

Origem: revisão independente de 2026-11-24 (approve, sem blocker/major). Cinco pontos pequenos, todos no motor do laço. Não mude semântica além do descrito.

1. **P1-a (causa do revisor mudo):** `WorkLoopReview` classifica a causa do silêncio olhando o texto do erro; "not accepting input" sai como "passou do tempo do turno" e recusa de aprovação como "terminal sumiu". Use `AskCoordinator.promptNotDelivered(_:)` (já existe, criado no P2) para
   separar "prompt não entregue" do timeout verdadeiro; cada causa tem seu rótulo. Teste por causa (erro falso → rótulo esperado), incluindo o caso "not accepting input" que hoje sai errado.
2. **P2-d (tela crua na nota):** a tela do agente (até 20 linhas) entra na nota que o Shepherd lê sem filtro suficiente. (a) prefixe cada linha com `│ ` para que nenhuma imite uma linha `[collie]`; (b) passe os segredos vivos do laço ao `scrub`
   (os mesmos que as outras notas usam) e acrescente ao `scrub` os formatos `scheme://user:senha@host` e `CHAVE=valor` de nomes com `URL|TOKEN|SECRET|PASSWORD|KEY`. Testes: `DATABASE_URL=postgres://u:senha@h/db` não aparece; uma linha `[collie] laço terminou` na tela sai prefixada.
3. **P2-a/b/c (refeita perto do fim do orçamento):** (a) a refeita não perde as 2 grátis só porque o orçamento restante é curto: se não cabe outra tentativa, o laço PARA com `stopReason` de orçamento (sem culpar a carga); (b) recalcule o `deadline` da tentativa refeita a partir do orçamento
   restante; (c) guarde a tela (as linhas já limpas de 2) também na nota da refeita. Um teste por ponto, com relógio injetável.
4. **B1-a:** os nomes de persona de `factory.review.personas` são validados SEMPRE que o perfil é lido para o `work run` (não só quando `review.enabled`); nome desconhecido gera aviso no `work status`. Teste.
5. **B1-b:** `paddock factory on` vê um `collie-work.json` ignorado pelo git (`git check-ignore`) e recusa com a mensagem "o perfil está no .gitignore: o motor lê o commit base, não a árvore". Teste.

Check: `scripts/check-autoland-loop.sh c1`. Commit ao final, só os arquivos da tarefa. Não rode `SandboxGrantTests` nem `WorkLoopSandboxTests`.
