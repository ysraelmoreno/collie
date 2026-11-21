# M6.4 O resumo imutável guarda a linha do tempo de um trabalho fechado com laço rodando

Leia `onda6.md` e o **achado A4** de `rev-onda5-report.md`. Código: `Sources/CollieDaemonKit/Work/WorkStore.swift` (~39 `closes()`, ~252 `enforce`: corta `loop.events` para 20 quando `closedAt != nil`), `WorkCommands.swift` (~223 `work.done` não recusa laço rodando), `Tests/CollieDaemonKitTests/WorkArchiveTests.swift` (`aWorkClosedUnderARunningLoopIsSummarizedWhenTheLoopEnds` **atribui** `events(150)` e mascara o defeito).

## Fazer
1. `enforce` **não corta** o diário enquanto `w.loop?.state == .running` (condição `closedAt != nil && loop?.state != .running`); o corte para 20 só vale depois que o laço termina e o resumo foi gravado.
2. O resumo imutável de um trabalho fechado com o laço rodando é gravado **quando o laço termina**, com a linha do tempo completa (até 500 eventos), como a spec da T6.1 promete.
3. O teste passa a reproduzir o laço real: **acrescenta eventos em várias escritas** sobre um trabalho já fechado com o laço rodando, termina o laço e confere a linha do tempo inteira (mais de 20, em ordem).

## Testes (escrever antes) — novo `Tests/CollieDaemonKitTests/ArchiveRunningLoopTests.swift`
Fechar com o laço rodando + 150 eventos em escritas separadas ⇒ o resumo tem os 150 (até o limite de 500, com `truncated` acima); depois do fim do laço o diário em memória volta ao corte de 20; sem laço rodando o comportamento é o de antes (regressão); o arquivo continua imutável. `WorkArchiveTests` segue verde (com o teste mascarado corrigido, diga no commit).
