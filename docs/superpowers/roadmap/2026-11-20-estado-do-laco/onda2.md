# Estado do laço, Onda 2: o Pastor lê o estado, e o laço aguenta o que hoje o derruba

Continua `README.md` (Onda 1: motivo de parada, diário, decisão pura, `AttemptMachine`; tudo já no branch). A Onda 1 não mudou comportamento. **A Onda 2 muda**, sempre no sentido de "o laço não depende do que o terminal diz".

## Princípio

O estado do laço é o que o **daemon observa** (commit, saída do check, terminal vivo, relógio), nunca o que o agente diz ou o que foi digitado num terminal. O Pastor **lê** esse estado (pull); a injeção de texto vira só uma dica.

## Tarefas (nesta ordem)

| # | Tarefa | O problema que resolve |
|---|---|---|
| M2.0 | Reenviar o Enter antes de falhar o prompt | o prompt fica digitado e não é submetido sob carga: `did not submit the prompt` queima a tentativa sem o agente ter trabalhado (M1b.2, 2026-11-20: 2 de 3 tentativas). **Aprovado pelo dono em 2026-11-20** (toca no `AskCoordinator`) |
| M2.1 | Toque em fim de turno prematuro | o agente encerra o turno cedo (pergunta, diálogo, compactação), o `ask` volta `.hook` e a tentativa morre em segundos com "no new commit" (A2.2, 2026-11-19: duas tentativas queimadas com 7 s) |
| M2.2 | Retomar o commit que já existe após queda | o `collied` cai com o commit feito e a tarefa aberta: hoje a retomada chama um agente novo e duplica trabalho (B1.2, 2026-11-18) |
| M2.3 | `collie work wait` e status com tempo | o Pastor espera por texto injetado; falta um "me avise quando o estado mudar" feito pelo daemon, e o status não diz há quanto tempo está na fase nem quando ela vence |
| M2.4 | Orientação do Pastor e `/collie:loop` | ensinar a usar `work wait`/`status` em vez de esperar aviso no terminal |
| M2.5 | `collie work task reopen` | não há como reabrir uma tarefa adiada (hoje: dropar e adicionar de novo, perdendo a ordem) |

## Fora do escopo

Mudar `ask`/`inject`/`AskCoordinator` além do reenvio único da M2.0 (o Enter por timer é outra onda); delegação por `ask` fora do laço; mudar o prompt da tentativa; erro de ambiente parando o laço; qualquer coisa de interface além de ler campos novos opcionais.

## Regras (as da Onda 1, mais estas)

Mesmas regras de `README.md`. Campos novos são opcionais, decodificam de arquivos antigos e **toleram raw values desconhecidos** (uma versão futura ou anterior não pode derrubar o `loop` inteiro). Cada mudança de comportamento tem um teste que falha antes. A `AttemptMachine` continua pura: um comportamento novo é um evento ou efeito novo, com linhas novas na tabela de testes. O motor novo só vale com o bundle instalado pelo dono. Verificação: `scripts/laco-check.sh M2.n` (cumulativo: roda todas as suítes da família).
