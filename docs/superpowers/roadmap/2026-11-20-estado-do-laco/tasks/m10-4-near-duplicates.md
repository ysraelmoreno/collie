# M10.4 Memórias quase duplicadas não entram juntas na injeção

Leia `onda10.md`. Medida: numa mesma sessão entraram 5 armadilhas do mesmo assunto ("escrever na worktree derruba a tentativa": ids diferentes, textos parecidos). O livro de injeção só barra o **mesmo id**. Código: `Sources/CollieDaemonKit/Memory/MemoryService.swift` (`hits`, `checklistParts`, `relevantLine`, ~465-500), `Memory/Consolidation.swift`, `Memory/ChecklistRanking.swift`, `Memory/MemoryIndex.swift` (vetores).

## Fazer
1. Ao montar um bloco de injeção (checklist, relevantes, foco), antes de cortar por orçamento, **agrupar candidatas quase iguais** (mesmo `subject` ou similaridade de vetor/termos acima de um limiar fixo e documentado) e injetar **só a melhor de cada grupo** (maior pontuação; empate: a mais recente e a de maior número de confirmações); as demais do grupo contam como vistas no livro da sessão (não voltam) e entram em `memory stats` como `collapsed`.
2. Sem vetor/embedder disponível, usar só `subject` igual e interseção de termos do título; nunca falhar a injeção.
3. Nada é apagado nem alterado no repositório de memória: é só a seleção da injeção. A consolidação existente continua sendo quem funde de verdade.

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/InjectionDedupTests.swift`
Cinco registros do mesmo assunto e dois de assuntos distintos → entram 1 + 2; a melhor do grupo vence (pontuação, depois recência); as colapsadas não voltam no prompt seguinte; sem embedder, o agrupamento por `subject`/termos funciona; o orçamento de bytes é respeitado e o que sobra de orçamento vai para candidatas distintas; o repositório de memória fica idêntico antes e depois. O fake aplica a regra real.
