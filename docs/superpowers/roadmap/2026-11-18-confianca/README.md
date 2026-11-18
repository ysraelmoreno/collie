# Roadmap: confiança nos agentes

Origem: palestra "All Code Is Slop (Except Mine)", Lauren Tan (2026). Tese: toda vez que se corrige um agente, a
correção vira checagem determinística (lint, tipo, teste, arquitetura), não mais uma linha de prosa; e a maior parte dos
tokens vai para verificação. Este roadmap aplica isso em duas frentes:

- **A: como construímos o Collie** (o repo): CI em PR, lint em catraca, arquitetura imposta.
- **B: o que o Collie oferece** a quem orquestra agentes: portões e evidência no laço, memória que vira regra, mapa de
  funcionalidades, métrica de confiança.

Estado em 2026-11-18 (medido): nenhum CI roda em PR (`release.yml`/`figcraft.yml` só em tag/manual); sem linter;
106 `Task.sleep`/`asyncAfter`/`usleep` e 59 `@unchecked Sendable`/`nonisolated(unsafe)` em `Sources/`, 8 `try!`/`as!`;
fronteiras de módulo só no `Package.swift` e em comentários.

## PRDs

| PRD | Frente | O quê |
|---|---|---|
| [A1](prd-a1-ci-pr.md) | repo | CI em PR com testes só dos targets afetados |
| [A2](prd-a2-lint-catraca.md) | repo | Lint em catraca: sleeps, escapes de concorrência, `try!`/`as!` |
| [A3](prd-a3-arquitetura.md) | repo | Fronteiras de módulo verificadas (imports × dependências declaradas) |
| [B1](prd-b1-evidencia.md) | produto | Evidência por tarefa do laço (commits, diff, saída do check, arquivos) |
| [B2](prd-b2-portao.md) | produto | Portão do laço: um check comum a todas as tarefas, aprovado uma vez |
| [B3](prd-b3-armadilha-regra.md) | produto | Armadilha da memória vira regra (inclui A4, o processo manual) |
| [B4](prd-b4-mapa-funcionalidades.md) | ambos | Mapa de funcionalidades: vocabulário comum para agentes e verificação |
| [B5](prd-b5-metrica-confianca.md) | produto | Métrica de confiança do laço: 1ª tentativa, adiadas, reverts |

## Ondas (cada onda = um `collie work run`)

A ordem importa: a onda 1 cria os scripts que as outras usam como check; a onda 2 cria o `--gate`, que as ondas 3+ usam.
Cada onda cabe no cartão de aprovação (≤ 1500 caracteres para todas as tarefas e checks).

| Onda | Tarefas (spec em `tasks/`) | Depende de |
|---|---|---|
| 1 Fundação | A2.1, A3.1, A1.2 (A1.1 cancelada: o CI roda a suíte inteira) | nada |
| 2 Portão e evidência | B2.1, B1.1, B1.2, B2.2 | onda 1 |
| 3 Memória que vira regra | B3.1, B3.2, B3.3 | onda 2 (usa `--gate`) |
| 4 Vocabulário e métrica | B4.1, B4.2, B5.1, B5.2 | onda 2 (B5.2 usa os commits de B1.1) |
| 5 Queima (opcional) | B1.3, A2.2, A2.3 | ondas 1 e 2 |
| manual | A4 (converter armadilhas reais em checagem) | onda 3 |

Os checks exatos de cada tarefa estão em [`waves.md`](waves.md), prontos para `collie work task add`.

## Antes do primeiro laço

1. O dono aprova estes PRDs (o que for cortado sai de `waves.md`).
2. Um cercado com a worktree limpa num branch novo a partir de `origin/main` (este cercado está em `feat/doc-memory`).
   Os specs precisam existir nesse cercado: commitar esta pasta lá primeiro.
3. Onda 1 roda com o `/collie:loop` (ou `work task add` + `work run`), aprovação no cartão.
4. Ao fim de cada onda: o dono revisa o diff e as notas, faz o land, e só então dispara a próxima.
5. As ondas 2+ mudam o próprio laço: `--gate` e a evidência só valem no Collie **instalado** depois de um release (ou
   do build do branch instalado). Até lá, as ondas 3–4 rodam sem `--gate` (ver `waves.md`).

## O que o laço não garante

O check verifica o spec, não o resultado (lição do relevance floor, `2026-11-17-work-run-design.md`). Cada PRD tem uma
seção **Medida de resultado** que o dono confere à mão depois do land.

## Fora do escopo (por enquanto)

Verificação formal (TLA+/Lean) e property-based testing de UI: a palestra trata como experimento; nada no Collie hoje
tem um fluxo cuja falha justifique o custo. Reavaliar quando houver um bug de concorrência que testes não pegaram.
Banir comentários: os comentários do Collie explicam porquês (fronteiras, specs), não remendos. A parte útil (regra
escrita em comentário vira teste) está em A3.
