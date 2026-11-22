# Trilho 2: laços ao vivo e histórico de laços (auditoria)

Pedido do dono (2026-11-21), em cima do layout Trilho (`../2026-11-19-trilho/`, já no branch). Mudanças:

1. **Seção LAÇOS no `ContextPanel`**: só existe enquanto há um laço **rodando** no trabalho ativo do cercado (nenhuma seção vazia).
2. **Seção HISTÓRICO** (sempre presente quando o cercado tem histórico): os **últimos 20** laços/trabalhos do cercado: data e hora, título, resultado, duração. Sem filtro.
3. **Detalhe no canvas**: clicar numa linha do histórico abre uma Prévia no canvas com a auditoria daquele trabalho (tarefas, tentativas, linha do tempo, commits).
4. **Resumo imutável (opção B)**: ao fechar um trabalho o daemon grava um arquivo de resumo que nunca muda, com a linha do tempo **completa** (hoje o diário de um trabalho fechado é cortado em 20 eventos).
5. **Conserto do diálogo "Abrir painel"** com o plug-in Prévia (exige `--file` ou `--artifact` e o diálogo não tem o campo: `give --file <page.html> or --artifact <id>`).

Só **a Completa** (a Compacta e a janela de Ajustes não mudam). A parte do motor (T6.1) **exige revisão independente antes do bundle**.

## Princípios
- Dado vem do **daemon** (`work.status`, `work.wait`, `work.list`, `work.history`); o app não inventa estado de laço. A UI é função pura de um modelo (`LoopSection`, `HistoryRow`) com tabela de testes.
- **Todo texto que veio do trabalho (título de tarefa, nota, razão, nome de agente) é dado**: no HTML do detalhe é **escapado** (HTML e atributos), nunca interpretado; nada de script, nada de URL externa.
- O daemon já guarda: `Work` (tarefas, `loop: WorkLoopState` com `stopReason`, diário em anel de 100; 20 nos fechados), `work.list --closed` com `closedAt`, e `work.summary` (markdown). Existe o painel Work em `Sources/ColliePlugins/WorkPanel.swift` (veja o que reaproveitar: `WorkListing`, `work.summary`). **Não reescreva o que já existe.**
- Sem `sleep` novo, campos novos opcionais e tolerantes, só `work.*` no app.

## Tarefas (nesta ordem)

| # | Tarefa | Teste que a prova |
|---|---|---|
| T6.1 | Resumo imutável ao fechar + `work.history` (motor) | arquivo gravado uma vez, imutável, linha do tempo completa, escopo por cercado, retenção |
| T6.2 | Modelo do app: `LoopSection` (visibilidade) e `HistoryRow` | tabela: sem trabalho / sem laço / rodando / terminado / parado |
| T6.3 | Seção LAÇOS no `ContextPanel` | só com laço rodando; linhas por tarefa; fases |
| T6.4 | Seção HISTÓRICO (últimos 20) | 20 mais recentes, ordem, formato de data/hora e duração |
| T6.5 | Detalhe no canvas (Prévia gerada do resumo) | HTML escapado, arquivo no cache do app, abre pelo painel Prévia |
| T6.6 | Diálogo "Abrir painel" com o seletor da Prévia | Prévia sem arquivo é recusada na UI; com artifact/arquivo abre |

## Fora do escopo
Filtros do histórico; exportar; apagar histórico pela UI; a visão gerada ("Gerar visão do laço"); layout Compacta; mudar o motor do laço além de T6.1.

## Regras
As do roadmap do laço (`../2026-11-20-estado-do-laco/README.md`, "Regras aprendidas na prática"). Verificação: `scripts/onda4-check.sh T6.n` (cumulativo).
