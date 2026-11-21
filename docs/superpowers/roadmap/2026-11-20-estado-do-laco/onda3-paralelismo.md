# Estado do laço, Onda 3: tarefas em paralelo (faixas)

Pedido do dono (2026-11-20): "uma onda própria para paralelismo", depois da Onda 2. Continua `README.md` (Onda 1) e `onda2.md`. **Ainda vale a regra do dono de não criar cercados novos**: as faixas abaixo **não são cercados** (não aparecem no app, não têm status, não são terminais do dono): são worktrees internos e temporários do laço, criados, integrados e apagados pelo próprio laço.

## Por que o laço é sequencial hoje (e o que muda)

Uma worktree só; o laço a reseta entre tentativas e vê qualquer arquivo rastreado modificado como sujeira; um laço por cercado; um agente por vez. Paralelismo de verdade pede **isolamento por tarefa** e um passo de **integração**.

## O desenho

- **Faixa (lane):** para cada tarefa pronta para rodar em paralelo, o laço cria um worktree git novo a partir do HEAD atual do branch do cercado, num branch próprio (`collie/lane/<trabalho>-<tarefa>`), no mesmo lugar e pelo mesmo mecanismo que os worktrees dos cercados já usam (reaproveitar o código de `paddock create`, não reescrever). O agente da tentativa roda **na faixa**; o check e o gate rodam **na faixa**.
- **Grafo de tarefas:** `WorkTask.needs: [id]` (só começa depois de essas estarem `done` e **integradas**) e `WorkTask.scope: [glob]` (os caminhos que a tarefa pode tocar). Duas tarefas só rodam juntas se os `scope` **não se sobrepõem**; sem `scope`, a tarefa é **exclusiva** (roda sozinha, como hoje). `--parallel N` (padrão **1**, máximo 4): com 1, o comportamento é **exatamente** o de hoje.
- **Integração serial:** quando uma tarefa passa na faixa (check e gate), um único integrador, um de cada vez, a junta ao branch do cercado (merge sem fast-forward), **roda o gate de novo na árvore integrada** (duas tarefas que passam sozinhas podem quebrar juntas) e só então a tarefa vira `done`. Conflito ou gate quebrado depois do merge: o merge é desfeito, e a tarefa **refaz a tentativa a partir do HEAD novo** (gasta uma tentativa) ou é adiada com o motivo.
- **Estado compartilhado, sem corrida:** `--max`, `--budget` e `spent` continuam do laço inteiro, contados num único ponto (actor). Parar o laço para todas as faixas. Cada faixa executa a sua `AttemptMachine` (pura, Onda 1); o escalonador também é uma função pura (tabela de testes).
- **O Pastor lê:** `work status` mostra as faixas (tarefa, fase, desde quando), `work wait` (Onda 2) acorda com mudanças de qualquer faixa, o diário traz o id da faixa.

## Invariantes (cada tarefa tem testes que as provam)

1. `--parallel 1` (ou ausente) ⇒ comportamento idêntico ao da Onda 2; os testes existentes seguem verdes sem mudar expectativa.
2. Nada toca a worktree do cercado até a integração; só o integrador escreve nela, e só com a árvore limpa e sem outro agente trabalhando nela.
3. O laço nunca dá push, land, nem cria cercado. Toda faixa é removida ao fim do laço, ao parar, e na varredura de início do daemon (uma faixa órfã nunca fica para trás).
4. O sandbox da faixa é o **estrito do cercado**, com a faixa como projeto: o agente de uma faixa não lê nem escreve a worktree do cercado nem outra faixa.
5. Nenhum `sleep` novo; esperas por continuação ou por evento.

## Custos e riscos (não esconder do dono)

- **Compilação a frio:** um worktree novo não tem cache de build; um build Swift a frio passa de 10 minutos. Paralelismo só compensa para tarefas longas ou de áreas disjuntas. A spec M3.6 mede e documenta; o padrão continua sendo `--parallel 1`.
- **Conflito de integração:** `scope` disjunto reduz, não elimina (um arquivo de projeto, um `Package.swift`, um índice compartilhado). Por isso o gate roda de novo depois do merge.
- **Superfície de segurança nova:** o sandbox por faixa (M3.3) é a parte que mais merece revisão independente **antes** de qualquer instalação.
- **Concorrência no motor:** vários `await` no mesmo actor; as tarefas M3.5 e M3.7 exigem testes de ordem e de parada.

## Tarefas (nesta ordem; cada uma deixa tudo compilando e com os testes anteriores verdes)

| # | Tarefa | Teste que a prova |
|---|---|---|
| M3.1 | Modelo do grafo (`needs`, `scope`) e o escalonador puro | tabela: o que está pronto, exclusão por escopo, ciclos, N máximo |
| M3.2 | Worktree da faixa (criar, listar, remover, varrer órfãs) | repositórios git temporários |
| M3.3 | Sandbox e host da faixa | perfil da faixa não alcança a worktree do cercado; `othersWorking` por faixa |
| M3.4 | Integrador serial | merge limpo, conflito, gate pós-merge quebrado, árvore suja, desfazer |
| M3.5 | O escalonador no motor (`--parallel N`) | host falso com 2 e 3 faixas; `--parallel 1` idêntico; orçamento e `--max` compartilhados |
| M3.6 | Ciclo de vida, status e cartão | faixa órfã varrida; `work status`/`wait`/diário com faixas; cartão mostra `--parallel` |
| M3.7 | Ponta a ponta e documentação | repositório real temporário: 2 tarefas disjuntas integram; sobrepostas rodam em série; conflito refaz; parar mata tudo |
| M3.8 | Nomes coerentes para os agentes do laço (pedido do dono, 2026-11-20) | tabela de nomes; `loop-<id>` some; varredor reconhece o agente sem o prefixo |

## Fora do escopo

Paralelismo entre laços de cercados diferentes (já existe: um laço por cercado); agentes de modelos diferentes por faixa; interface gráfica das faixas além de ler os campos do status; push; fila entre trabalhos; reintegração de histórico (rebase interativo).

## Regras (as da Onda 1 e da Onda 2; mais)

Campos novos opcionais e tolerantes a valores desconhecidos. Verificação por `scripts/laco-check.sh M3.n`. O motor novo só vale com o bundle instalado pelo dono, e **a Onda 3 exige revisão independente antes de instalar** (sandbox por faixa + integração + concorrência).
