# PRD: Fábrica v0, o dono fora do caminho normal

Data: 2026-11-22. Estado: proposto (pedido do dono na conversa do mesmo dia). Continua o roadmap de confiança
(`../2026-11-18-confianca/`) e depende do `ci` verde (`../2026-11-22-ci-main/prd.md`).

## Problema

O Collie já tem o motor (laço com máquina de estados, faixas paralelas, handoff, retomada, resumo imutável) e os
guardrails determinísticos (`--check`, `--gate`, lint em catraca, `check-architecture.sh`, sandbox, leash, evidência,
plug-in Vizinho/Cercas). O que ainda não tem é **autonomia de ponta a ponta**: em cada onda o dono entra pelo menos
cinco vezes.

1. Escreve ou aprova o PRD e monta a `waves.md` à mão.
2. Aprova o cartão do laço.
3. Revisa o diff (ou monta um terminal `rev-onda*` à mão para revisar).
4. Faz o land e dispara a próxima onda.
5. Confere a "Medida de resultado" à mão, porque o check verifica o spec, não o resultado.

Medido em 2026-11-22: a main está sem `ci` verde desde 2026-11-20; só **2 de 802** memórias têm `enforcedBy`
(509 armadilhas em prosa); a revisão independente e a verificação no aparelho não fazem parte do laço.

## Objetivo

O caminho normal de uma onda roda sem o dono: **ideia aprovada → tarefas com checks → laço → revisão → verificação
de resultado → land**. O dono aprova uma vez (no PRD), recebe o resultado e só é chamado nas exceções (revisor
recusou duas vezes, verificação de resultado falhou, portão vermelho, decisão de produto).

## Não-objetivos

- **Push e release automáticos.** O push na main dispara release pública; continua sempre manual e do dono.
- Tirar o dono da decisão de produto (o quê e por quê). A fábrica automatiza o como.
- Revisor que edita código. Ele só julga.
- Verificação formal, property-based de UI (mesma decisão do roadmap de confiança).

## Anti-objetivos

- O agente que trabalha conseguir influenciar quem o julga: mudar o check, o portão, o revisor ou o critério de
  aceite na mesma tentativa.
- Land automático sem portão verde. Na dúvida, para e chama o dono (fail closed), ao contrário dos ganchos do
  Vizinho, que são fail open.
- Esconder falha para manter a fábrica andando (`ci-skip.txt` sem razão, tarefa adiada sem nota).

## Ondas (cada uma vale sozinha)

F1 corre em paralelo com F2 (decisão do dono, 2026-11-22): não mexem nos mesmos arquivos (F1 é memória e checagens
novas; F2 é `AttemptMachine`/`WorkLoop`).

| Onda | O quê | Por que nesta ordem | Depende de |
|---|---|---|---|
| F0 Portão do repo | `ci` verde na main, dois runs seguidos (o PRD `ci-main` inteiro) | sem portão confiável, nada abaixo é seguro | nada |
| F1 Correção vira regra em escala | converter armadilhas recorrentes em checagem (o A4 do roadmap de confiança, agora com meta) | é o maior ganho com o menor código: as peças (`memory list --candidates`, `memory enforce`, deriva) já existem | F0 (as checagens novas rodam no CI) |
| F2 Revisor no laço | fase `review` depois de `check`/`gate`: outro agente julga diff + evidência contra o spec; o Pastor escolhe agente e modelo por tarefa | tira o dono do passo 3 | F0 (em paralelo com F1) |
| F3 Verificação de resultado | critério de aceite executável por tarefa (`--accept`): cenário no aparelho, no navegador ou no app, além do teste | tira o dono do passo 5; fecha "spec ≠ resultado" | F2, device helper (branch `feat/trust-roadmap`) |
| F4 Land automático | só em cercado marcado como fábrica: portão + CI local + revisor + aceite verdes → land e próxima onda | tira o dono dos passos 2 e 4 | F2, F3 |
| F5 Entrada | ideia/PRD aprovado → rascunho de `waves.md` com tarefas, specs e checks, aprovado uma vez | só faz sentido com os portões de pé | F4 |

### F1 Correção vira regra em escala

- Rodar `collie memory list --candidates`, triar com o dono: vira lint, teste, schema ou mensagem de erro, ou
  continua prosa (armadilha que não é de código).
- Cada conversão é uma tarefa comum do laço mais `memory enforce <id> --by <caminho>`.
- O Pastor, ao fechar um trabalho em que o mesmo tipo de falha apareceu em duas tentativas, propõe a armadilha como
  candidata (nota no resumo), sem converter sozinho.
- Não começar antes de terminar a medição da memória (memória `memory-improvements-status`: publicada em
  2026-11-18, medir de 7 a 14 dias, ou seja, até 2026-12-02 no máximo).

### F2 Revisor no laço

- Fase nova `review` em `AttemptMachine`, depois de `check` e `gate`, só se o trabalho tiver revisor
  (`work run --review`, opt-in).
- O revisor é um terminal novo, sem coleira com o agente que trabalhou e sem o histórico dele. Recebe só o spec da
  tarefa, o diff da tentativa e a evidência (B1). Responde um JSON fixo
  (`{"verdict": "approve"|"reject", "reasons": [...]}`); qualquer outra resposta conta como `reject` com motivo.
- `reject` = nova tentativa com os motivos na nota, contando no `--tries`. Dois `reject` seguidos na mesma tarefa:
  adia e chama o dono.
- **Escolha de agente e modelo por tarefa** (decisão do dono, 2026-11-22): o Pastor escolhe, para quem trabalha e
  para quem revisa, o agente (Claude, Cursor, Codex) e o modelo, preferindo o mais barato que dá conta da tarefa
  (ex.: Haiku ou Sonnet para tarefa mecânica, Opus para motor e concorrência). A escolha e o motivo ficam na
  evidência e no resumo; `work task add --agent/--model` do dono sobrepõe. Regra única: o revisor nunca é o mesmo
  terminal de quem trabalhou (pode ser o mesmo modelo, com contexto limpo).
- Escalada: tarefa que falhou ou foi recusada com o modelo barato pode subir de modelo na tentativa seguinte; a
  subida conta no `--tries` e aparece na nota.
- Os relatórios `rev-onda*` de hoje servem de régua: o revisor do laço precisa achar o que eles acharam.

### F3 Verificação de resultado

- `work task add --accept "<comando>"`: roda depois do revisor, fora do controle do agente; o comando vem do spec
  aprovado e o agente não pode mudá-lo (o laço o lê do estado do trabalho, não da worktree).
- Os primeiros adaptadores usam o que já existe: `collie device ...` (helper deste branch), o navegador
  (Browser\*), os serviços de app do cercado. Sem framework novo.
- A falha do aceite vale como falha de check, com a saída inteira na evidência (lembrar da armadilha "check que mostra
  só o rabo").

### F4 Land automático

- **Só em cercado marcado como fábrica** (decisão do dono, 2026-11-22): marca persistente no cercado
  (`paddock create --factory` / `paddock factory <nome> on|off`), que só o dono liga; o agente não consegue ligar.
  Fora desses cercados, `--auto-land` é recusado.
- `work run --auto-land` (opt-in por trabalho, dentro do cercado fábrica): quando todas as tarefas estão `done` com portão, revisor e aceite
  verdes e o CI local (`scripts/ci/run-tests.sh` dos alvos afetados) passa, o laço faz o `paddock land` e, se houver,
  inicia o próximo trabalho da fila.
- Nunca faz push. O aviso de fim diz "pronto para push" com o resumo.
- Qualquer conflito de land, árvore suja ou portão vermelho: para com `stopReason` próprio e chama o dono.
- Fica registrado no resumo imutável (quem aprovou o quê), para a auditoria do Trilho 2.

### F5 Entrada

- A partir de um PRD aprovado (formato destes roadmaps), o Pastor gera o rascunho de `waves.md` e `tasks/*.md` com
  `--check`, `--gate` e `--accept`, dentro do limite do cartão (≤ 1500 caracteres).
- O dono aprova o pacote uma vez; os cartões por onda passam a ser aprovados pela política (F4) em vez de clique.
- Um linter de spec recusa tarefa sem check executável ou com check que só faz `grep` no próprio arquivo criado.

## Medida de resultado

- **Toques do dono por onda** (aprovação, revisão, land, nova tentativa à mão): de cerca de 5 hoje para 1 (o PRD)
  no caminho normal. Contar nos resumos imutáveis.
- **Taxa de 1ª tentativa e revertidos depois do land** (B5): não piora com a F2–F4 ligada.
- **Revisor útil:** em pelo menos 3 ondas, achou o que o `rev-onda*` manual achou, ou mais.
- **Armadilhas impostas:** de 2 para pelo menos 20 em 30 dias depois da F1; tokens de memória injetados por sessão
  caem (`memory stats`).
- **CI:** verde na main em 90% dos pushes do mês seguinte à F0.

## Riscos

- **Revisor carimbador** (aprova tudo). Mitigação: régua dos `rev-onda*`; tarefa-isca com defeito plantado de vez em
  quando para medir.
- **Land automático espalhando regressão.** Mitigação: opt-in, nunca push, fail closed, CI local antes do land.
- **Custo de tokens** (revisor e aceite por tentativa). Mitigação: revisor só depois de `check`/`gate` verdes;
  escolha do modelo mais barato que dá conta; `work usage` por tarefa e por modelo no resumo; `--budget` já existente.
- **Modelo barato demais** (economia vira retrabalho). Mitigação: escalada de modelo; medir custo total por tarefa
  feita (tentativas incluídas), não por tentativa.
- **Aceite frágil** (cenário de aparelho que falha por tempo). Mitigação: regras da Onda 11 (sem `sleep`, sem relógio
  de parede); falha de ambiente vira `stopReason` próprio, não `reject`.

## Decisões do dono (2026-11-22)

1. Agente e modelo (de quem trabalha e de quem revisa) escolhidos pelo Pastor por tarefa, preferindo os mais baratos.
2. Land automático só em cercados marcados como fábrica.
3. F1 corre em paralelo com F2.

## Perguntas abertas

1. Na F5, o Pastor pode propor PRD a partir de um card do Quadro, ou o PRD continua sempre escrito pelo dono?
