# PRD geral: Cursor no Collie com qualidade, mesmo com modelo fraco

Data: 2026-11-24. Estado: ordem e divisão aprovadas pelo dono na conversa (mecanismo no daemon, política em plug-in).

## Problema

Três rodadas de teste em 2026-11-24 com `cursor-agent` 2026.11.22-e9042b2 e o modelo Composer 2.5 (um líder, workers,
revisão entre pares, proposta de `/collie:loop`, navegador headless, artifact). O Composer usa bem as ferramentas do
Collie (`memory_task`, `ask --no-wait`, `ask result`, `lot post`, `reply`; a detecção de deadlock funcionou), e os
dados que entregou estavam certos. O que falhou:

1. **Qualidade.** O reviewer achou um bug real (`slugify("Straße")` → `stra-e`), chamou de "ressalva"; o builder tratou
   como opcional, declarou pronto e salvou o bug como armadilha em vez de corrigir. O curador promoveu essa armadilha,
   tirada de um arquivo descartável em `.collie/`, para a memória do projeto.
2. **Cursor convocado não delega.** `summon` é só de Pastor e só o app marca Pastor. O erro não diz o que fazer; o agente
   fez polling em `collie list` por ~3 min.
3. **Cursor por comando custom é tratado como "outro".** Para escolher o modelo é preciso `--preset custom --command
   "cursor-agent --model composer-2.5"` (o `--model` do `summon` é só do Claude). Vários pontos testam só
   `preset == .cursor`: o cartão do diálogo de confiança e das permissões (`AttentionDetector.swift:37`), o aviso de
   resposta digitado no asker (`CommandRouter.swift:562`), o `replyHint` (`AskCoordinator.swift:441`). O terminal
   ficou parado no "Workspace Trust Required" sem cartão.
4. **`summon --prompt` no Cursor fica digitado sem Enter.** O `wait` responde `idle:true` na hora e o `ask` seguinte
   gruda no texto (`…sentence.Go.`).
5. **`ask` bloqueante pelo MCP no Cursor** estoura o timeout do cliente MCP do Cursor (`-32001`), com o alvo terminando
   normalmente depois.
6. **Resposta por ociosidade** é o texto do scrollback: ~1k linhas de spinner e moldura do Ink a cada repintura.
7. **Aviso de resposta repetido.** O `[collie] Reply from …` é digitado mesmo depois de o asker ler a resposta com
   `ask result`: um turno gasto por aviso, sem informação nova.
8. **Hooks do Cursor subutilizados.** Medido em 2026-11-24 com um plug-in sonda (`--plugin-dir`): no interativo disparam
   `sessionStart`, `preToolUse`, `postToolUse`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`,
   `afterAgentThought`; no `-p` também `beforeShellExecution`, `afterShellExecution`, `sessionEnd`. Não disparam
   `stop`, `afterAgentResponse`, `beforeSubmitPrompt`. O spike (`docs/superpowers/spikes/2026-10-22-cursor/REPORT.md`
   §8) e `docs/referencia.md` ainda dizem "só sessionStart".

## Objetivo

O modelo fraco não decide que terminou: um comando decide, escrito por quem é forte. O Collie dá o portão e o canal;
o modelo barato faz o volume.

1. Cursor custom e preset se comportam igual; launch, ask e reply sem as arestas acima (onda 1).
2. Um Pastor pode convocar um sub-Pastor (onda 2).
3. `ask` com portão: só termina quando o check passa; check que já passa antes da tentativa é recusado; escalada de
   modelo depois de N falhas (onda 3).
4. Eventos de ferramenta do Cursor chegam ao contrato de plug-in (`edit`), e Vizinho/Cercas valem no Cursor (onda 4).
5. Plug-in "Treinador" com a política para agentes fracos (onda 5).

## Divisão daemon × plug-in

Segue `docs/superpowers/roadmap/2026-11-20-ganchos-plugin/README.md`: o daemon só conhece o contrato; a lógica de
padrões mora no plug-in; o agente nunca instala, altera ou desliga o que o julga.

- **Daemon:** tudo que é launch, ask, reply, idle, permissão, grafo de guias, memória; o juiz (check, portão,
  escalada); a ponte de eventos do Cursor.
- **Plug-in:** orientação e bloqueio na edição e no fim de turno, conversão de achados de revisão em casos.

## Não-objetivos

- Mudar o lugar dos artifacts (`docs/pages/`). É o desenho atual da Prévia; o caso da rodada 3 foi pedido sem dizer
  onde. Rever só se aparecer de novo com o destino dito.
- Revisor por LLM no daemon. O juiz é sempre um comando.
- Melhor-de-N (N tentativas baratas em faixas, a primeira que passa vence). Fica para depois da onda 3, com medida.

## Medida de resultado

- Repetir as três rodadas de 2026-11-24 (roteiro em "Rodadas de referência") com Composer 2.5 e comando custom:
  nenhuma intervenção manual (trust, Enter, `check`), resposta de `ask` sem moldura do Ink, nenhum aviso repetido.
- Com `ask --check` e o caso `Straße → strasse` no check, o builder não termina sem corrigir.
- Um Pastor Cursor convoca um sub-Pastor, que convoca 2 workers, e o resultado volta ao Pastor de cima.

## Rodadas de referência

1. Líder Cursor: convocar `counter` (contar `.swift` por pasta de `Sources/`) e `todo-hunter` (top 5 arquivos com mais
   `ponytail:`), juntar as respostas.
2. Pastor + builder Cursor + reviewer Cursor ligados entre si, num lote: `slugify` com testes em `.collie/cursor-test/`,
   revisão pedida pelo builder, handoff no quadro.
3. Proposta de `/collie:loop` (sem rodar) + `panel open browser` headless + `artifact new doc`.

## PRDs e ondas

Portão comum:

```
scripts/ci/lint.sh && scripts/ci/check-architecture.sh
```

| Onda | PRD | O quê | Depende de |
|---|---|---|---|
| 1 | [A1](prd-a1-cursor-custom.md) | um Cursor por comando custom é Cursor em todo lugar | — |
| 1 | [A2](prd-a2-cursor-launch.md) | `--model` e `--trust` no preset `cursor` | — |
| 1 | [A3](prd-a3-cursor-envio.md) | primeiro prompt e ask enviados de fato (Enter confirmado) | — |
| 1 | [A4](prd-a4-resposta-limpa.md) | resposta por ociosidade sem moldura do Ink | — |
| 1 | [A5](prd-a5-aviso-lido.md) | aviso de resposta não repetido depois de `ask result` | — |
| 1 | [A6](prd-a6-mcp-cursor.md) | `ask`/`wait` bloqueantes no MCP do Cursor viram id + espera | — |
| 1 | [A7](prd-a7-curador-rascunho.md) | curador não promove rascunho de lote para o projeto | — |
| 2 | [B1](prd-b1-sub-pastor.md) | `summon --shepherd`: sub-Pastor, profundidade 2, dispensa em cascata | A1 |
| 2 | [B2](prd-b2-sub-pastor-app.md) | app mostra a árvore e revoga | B1 |
| 3 | [C1](prd-c1-ask-portao.md) | `ask --check --spec --tries` | A3, A4 |
| 3 | [C2](prd-c2-check-vermelho.md) | check que já passa antes da tentativa é recusado (laço e ask) | C1 |
| 3 | [C3](prd-c3-escalada.md) | `--escalate agente:modelo,…` no laço | C2, A2 |
| 4 | [D1](prd-d1-ponte-cursor.md) | hooks de ferramenta do Cursor → evento `edit` do contrato; sinal de ocupado | A1 |
| 5 | [E1](prd-e1-treinador.md) | plug-in Treinador (a detalhar) | D1, C1 |

As tarefas de uma onda tocam arquivos diferentes e rodam em paralelo, cada uma num terminal. Exceções, em série por tocarem
os mesmos arquivos: A1 → A3 → A4 (`AskCoordinator.swift`) e A1 → A5 (`CommandRouter.swift`).
