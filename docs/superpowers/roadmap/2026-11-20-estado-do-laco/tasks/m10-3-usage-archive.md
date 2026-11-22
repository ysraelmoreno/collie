# M10.3 Tokens por tentativa no resumo imutável e `work usage` para trabalho fechado

Leia `onda10.md` e a proposta P6 de `aval-lacos-report.md`. Código: `Sources/CollieCore/WorkArchive.swift`, `Sources/CollieDaemonKit/Work/WorkSummary.swift` (ou onde o resumo é montado), `WorkArchiveFiles.swift`, `Memory/SessionUsage.swift` (`attemptTokens`, `TokenCount`), `WorkCommands.swift` (`work.usage`), `Sources/CollieApp/LoopsSheet.swift` (detalhe do histórico).

## Fazer
1. O resumo imutável (`WorkArchive`) ganha, por tarefa, as tentativas com `TokenCount` (entrada, saída, cache criado, cache lido, mensagens), o modelo, e os segundos de agente e de check; tudo **opcional** (arquivos antigos continuam legíveis).
2. `collie work usage [--id <trabalho>]` passa a ler os arquivos para trabalhos **fechados** (hoje responde "Nenhum trabalho neste cercado"); mesmo escopo de cercado do `work history` (M7.1).
3. O detalhe do histórico no modal "Laços" mostra o total de tokens (índice relativo) e por tarefa; nada quando o arquivo não tem os dados.
4. Nunca texto de conversa: só números e o nome do modelo.

## Testes (escrever antes) — `Tests/CollieDaemonKitTests/ArchiveUsageTests.swift`
Arquivo antigo sem os campos decodifica; arquivo novo com os campos faz ida e volta; `work usage` de trabalho fechado do próprio cercado devolve os números; de outro cercado, não devolve; o detalhe mostra o total; limite de 500 eventos/1 MB preservado. O fake aplica a regra real.
