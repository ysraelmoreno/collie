# PRD B3: armadilha vira regra (inclui A4)

## Problema

A memória do Collie guarda armadilhas (`kind` pitfall) e as injeta no contexto dos agentes (hook de prompt, checklist).
É a camada de "prosa" da pirâmide da palestra: depende do agente ler e obedecer, custa tokens em toda sessão, e envelhece.
Exemplo real: a armadilha "Nome de campo errado em chamada de ferramenta MCP" é recuperada repetidamente; um schema
mais estrito ou uma mensagem de erro melhor eliminaria a classe inteira.

A palestra: "toda vez que corrigimos um agente, vira checagem determinística ou eliminamos o problema por design".

## Objetivo

1. Uma armadilha pode ser marcada como **imposta por** uma checagem (arquivo de lint, teste, regra). Imposta, ela sai da
   injeção (economiza tokens) e continua pesquisável.
2. O Collie aponta quais armadilhas são **candidatas**: muito recuperadas e ainda não impostas.
3. Se a checagem que a impõe some do repo, a armadilha volta a ser injetada e é sinalizada.
4. (A4, manual) O dono e um agente convertem as candidatas reais de hoje.

## Não-objetivos

- Gerar a regra de lint automaticamente. O Collie aponta; quem escreve a checagem é um agente numa tarefa normal.
- Tirar armadilhas que não são de código (ex.: "reiniciar o serviço derruba os terminais"): essas continuam prosa.

## Requisitos

1. `MemoryRecord` ganha `enforcedBy: String?` (caminho relativo à raiz do repo; opcional, decodifica antigos).
2. `collie memory enforce <id> --by <caminho>` e a ferramenta MCP equivalente (`memory_enforce`): só para pitfall/decisão,
   caminho precisa existir na worktree de quem chama; `--clear` remove. Evento no log de memória.
3. Item com `enforcedBy`: fora do hook de memória relacionada e do checklist; `memory get`/`search` mostram
   "imposta por <caminho>".
4. Candidatas: pitfalls `active`, sem `enforcedBy`, com `hits ≥ 3` (constante nomeada). `collie memory list --candidates`
   e uma seção em `memory stats`. A orientação do Pastor ganha uma linha só quando há candidatas
   ("N armadilhas recorrentes podem virar checagem: `collie memory list --candidates`").
5. Deriva: junto do passe de deriva de mapa (`MapDrift.mapDriftPass`), itens com `enforcedBy` cujo caminho não existe
   mais na worktree: limpa `enforcedBy` (volta à injeção) e grava um `LifecycleFlag(verdict: .outdated, …)` com motivo
   `enforcedBy gone: <caminho>`, como a deriva de mapa já faz. Evento no log.
6. `MemoryRecord` tem formato texto próprio (chaves `kind: valor`, parse com `kv[…]`): `enforcedBy` entra nele também.
7. **A4 (manual, depois da onda 3):** listar as candidatas reais; para cada uma decidir: virar lint/teste/schema, ou
   continuar prosa. Converter pelo menos 3. Cada conversão = uma tarefa comum (pode ir num laço) + `memory enforce`.

## Medida de resultado

- Tokens de memória injetados por sessão caem (comparar `memory stats` antes/depois, mesma janela de 7 dias da
  medição em curso; não começar antes da medição de 2026-11-18 terminar, ver memória `memory-improvements-status`).
- Pelo menos 3 armadilhas impostas por checagem em 30 dias.

## Tarefas

- B3.1 `enforcedBy` e `memory enforce` (`tasks/b3-1-enforced-by.md`)
- B3.2 candidatas (`tasks/b3-2-candidates.md`)
- B3.3 deriva (`tasks/b3-3-enforced-drift.md`)
- A4 manual (sem spec de laço)

## Riscos

- Mexe na injeção durante a medição da memória. Mitigação: B3.1 só tira da injeção itens com `enforcedBy`, que não
  existem até alguém rodar `memory enforce`; nada muda na medição até A4.
